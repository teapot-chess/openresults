# Last run's FIDE list databases - see `OpenResults.FideListCase.root/0`.
File.rm_rf(OpenResults.FideListCase.root())

# The results hub load test publishes 10,000 tournaments; it runs on request
# only - see `OpenResultsWeb.ResultsHubLoadTest`.
ExUnit.start(exclude: [:load_test])
Ecto.Adapters.SQL.Sandbox.mode(OpenResults.Repo, :manual)
