--- `namespace-decl` ships `off`; this fixture turns it on so both halves of the
--- split are visible in one expectation.
return {
  source_roots = { "." },
  inherit_path = false,
  severity = { ["namespace-decl"] = "error" },
}
