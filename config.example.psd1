# Copy to config.psd1 (gitignored) and adjust for this machine.
# Any setting left out uses the default in host/New-DevHostVM.ps1, and any
# parameter passed on the command line overrides this file.
@{
    VMName     = 'devhost'

    # Ubuntu Server ISO. Downloaded once to .cache/ and verified against IsoSha256.
    # Checksums: https://releases.ubuntu.com/<version>/SHA256SUMS
    IsoUrl     = 'https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-live-server-amd64.iso'
    IsoSha256  = 'cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927'

    # Use an ISO you already have instead of downloading. Still checked against IsoSha256.
    # IsoPath  = 'C:\Users\you\Downloads\ubuntu-26.04.1-live-server-amd64.iso'

    # Where the VM and its disk live. Default: Hyper-V's configured VM path.
    # VMRoot   = 'D:\Hyper-V'

    # External switch, bound to a physical adapter. Default: the physical adapter
    # with the default gateway.
    SwitchName = 'LAN'
    # NetAdapter = 'Ethernet'

    # Sizing. vCPUs are shared, not reserved; memory is dynamic.
    CpuCount   = 4
    CpuWeight  = 50       # 100 is the Hyper-V default; lower lets the host win contention
    MemStartup = 4GB
    MemMinimum = 2GB
    MemMaximum = 8GB
    DiskSize   = 128GB    # dynamic VHDX: only uses what is stored
}
