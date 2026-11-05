@{
    RootModule        = 'MsixSandboxStudio.psm1'
    ModuleVersion     = '9.9.9'
    GUID              = '5d1c7a3e-0b4f-4b57-9a61-2f8f6f1c9a10'
    Author            = 'GUI smoke test'
    Description       = 'Fake MSIX Sandbox Studio: records the test project, never opens a sandbox'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('New-Win32Detection', 'Save-Win32AppProject', 'Start-Win32TestLab')
}
