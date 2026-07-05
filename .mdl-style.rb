all

# Carried over from mdl's built-in "default" style.
exclude_rule 'MD040' # Fenced code blocks should have a language specified
exclude_rule 'MD041' # First line in file should be a top level header

# This repo's conventions differ from mdl's defaults:
exclude_rule 'MD013' # Line length -- prose docs run long by design, not wrapped
exclude_rule 'MD033' # Inline HTML -- angle-bracket <placeholder> convention in directive docs
exclude_rule 'MD007' # Unordered list indentation -- nested bullets use 2 spaces here, not mdl's default 3
rule 'MD029', :style => :ordered # docs number real sequential steps, not mdl's default "every item is 1."
rule 'MD046', :style => :consistent # some directive docs use indented example blocks throughout; each file is internally consistent
