"""Render spack.yaml from the environment template plus a fabric fragment.

Run with Spack's own interpreter (`spack python render-env.py ...`) so PyYAML is
available without adding a dependency to the cluster image.

    spack python render-env.py FRAGMENT TEMPLATE OUT TARGET GPU_ACTIVE CUDA_ARCH MODULE_ROOT

It must be a real file: `spack python -` does not read a script from stdin the
way `python -` does -- it tries to open "-" as a filename.

The `packages:` section is merged STRUCTURALLY, not by text substitution. Both
sides legitimately configure the same package: the template pins MPI versions
globally, the fragment sets the fabric-specific variants. Splicing the fragment
in as text produced a YAML file with two `openmpi:` keys, which Spack rejects
outright ("found duplicate key"). Merging the parsed dicts -- and concatenating
`require` lists rather than letting one win -- is what lets both live together.
"""

import sys

import yaml

SPEC_PLACEHOLDERS = ("__MPI_SPECS__", "__CUDA_AWARE_MPI_SPECS__",
                     "__GROMACS_SPECS__", "__GROMACS_GPU_SPECS__")


def merge_packages(base, extra):
    """Deep-merge fragment package config into the template's.

    `require` lists are concatenated so a global version pin and a fabric
    variant requirement both apply; any other key the fragment sets wins.
    """
    for pkg, cfg in (extra or {}).items():
        if pkg not in base:
            base[pkg] = cfg
            continue
        merged = dict(base[pkg])
        for key, value in cfg.items():
            if key == "require":
                old = merged.get("require", [])
                old = [old] if isinstance(old, str) else list(old)
                new = [value] if isinstance(value, str) else list(value)
                merged["require"] = old + [v for v in new if v not in old]
            else:
                merged[key] = value
        base[pkg] = merged
    return base


def main(argv):
    frag_path, tmpl_path, out_path, target, gpu_active, cuda_arch, module_root = argv[1:8]
    gpu_active = gpu_active == "1"

    with open(frag_path) as f:
        frag = yaml.safe_load(f)["fabric"]

    def specs_block(key, only_if=True):
        if not only_if:
            return ""
        items = [s.replace("__CUDA_ARCH__", cuda_arch) for s in frag.get(key, [])]
        return "\n".join('    - "%s"' % s for s in items)

    with open(tmpl_path) as f:
        tmpl = f.read()

    # The fragment's packages are merged after parsing, so drop the placeholder line.
    tmpl = "\n".join(l for l in tmpl.split("\n") if l.strip() != "__FABRIC_PACKAGES__")

    for placeholder, value in [
        ("__TARGET__", target),
        ("__MODULE_ROOT__", module_root),
        ("__MPI_SPECS__", specs_block("mpi_specs")),
        ("__CUDA_AWARE_MPI_SPECS__", specs_block("cuda_aware_mpi_specs", gpu_active)),
        ("__GROMACS_SPECS__", specs_block("gromacs_specs")),
        ("__GROMACS_GPU_SPECS__", specs_block("gromacs_gpu_specs", gpu_active)),
    ]:
        tmpl = tmpl.replace(placeholder, value)

    leftover = [p for p in SPEC_PLACEHOLDERS + ("__TARGET__", "__MODULE_ROOT__",
                                                "__FABRIC_PACKAGES__", "__CUDA_ARCH__")
                if p in tmpl]
    if leftover:
        sys.exit("render-env: unsubstituted placeholders remain: %s" % ", ".join(leftover))

    env = yaml.safe_load(tmpl)
    env["spack"]["packages"] = merge_packages(env["spack"].get("packages", {}),
                                              frag.get("packages", {}))

    # The stack compiler is written down only in the template. Report it so the
    # caller can install and register it before concretizing -- `spack python -c`
    # takes a single statement, so a multi-line inline reader is not an option.
    req = env["spack"]["packages"]["c"]["require"]
    gcc_spec = req[0] if isinstance(req, list) else req

    with open(out_path, "w") as f:
        yaml.safe_dump(env, f, default_flow_style=False, sort_keys=False, width=100)

    print("rendered %s: target=%s gpu=%s specs=%d"
          % (out_path, target, gpu_active, len(env["spack"]["specs"])))
    print("GCC_SPEC=%s" % gcc_spec)


if __name__ == "__main__":
    main(sys.argv)
