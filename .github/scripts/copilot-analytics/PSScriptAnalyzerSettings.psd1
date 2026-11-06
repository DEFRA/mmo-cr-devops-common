@{
    # The scripts run in GitHub Actions, where the host stream is the job log.
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
