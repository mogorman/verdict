# Dialyzer ignore file (Elixir term format), used via `dialyzer: [ignore_warnings:
# ".dialyzer_ignore.exs"]` in mix.exs.
#
# Keep this as small as possible: prefer a co-located `@dialyzer {:nowarn_function, ...}`
# (self-documenting) over an entry here, and prefer fixing the code over either.
# An entry here is only for noise that cannot be fixed locally (e.g. an upstream
# dependency that is not fully typed). `mix dialyzer --list-unused-filters` reports
# entries that no longer match anything; delete those.
#
# Entry forms (see `mix dialyzer.explain` and the dialyxir README):
#   {"path/to/file.ex", :warning_type, 123}
#   {"path/to/file.ex", :warning_type}
#   ~r/regex-matched-against-short-format/
[]
