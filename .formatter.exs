[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  export: [
    locals_without_parens: [timeless_metrics_dashboard: 1, timeless_metrics_dashboard: 2]
  ]
]
