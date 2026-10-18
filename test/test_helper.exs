# Last run's FIDE list databases - see `OpenResults.FideListCase.root/0`.
File.rm_rf(OpenResults.FideListCase.root())

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(OpenResults.Repo, :manual)
