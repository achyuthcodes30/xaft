import Config

config :xaft,
  peers: [
    :n1@localhost,
    :n2@localhost,
    :n3@localhost
  ],
  heartbeat: 100,
  election_min_timeout: 500,
  election_max_timeout: 800

config :logger, :console,
  level: :debug,
  colors: [
    enabled: true,
    debug: :cyan,
    info: :green,
    warn: :yellow,
    error: :red
  ]

config :elixir, :ansi_enabled, true
