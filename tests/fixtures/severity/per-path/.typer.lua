--- Holding library code to a higher standard than tests is what most projects
--- want, and a single global `--severity` cannot say it. Not a baseline: this
--- names paths, not defects, so nothing goes stale and nothing is hidden.
return {
  source_roots = { "lua" },
  inherit_path = false,
  overrides = {
    { paths = { "spec/**" }, severity = { ["*"] = "hint" } },
    -- A later, narrower block carves an exception out of the one above it.
    { paths = { "spec/strict_spec.lua" }, severity = { ["missing-param"] = "error" } },
  },
}
