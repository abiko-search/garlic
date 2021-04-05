import Config

config :logger, level: :debug

config :logger, :console,
  format: "$date $time $metadata[$level] $levelpad$message\n",
  metadata: [:circuit_id]
