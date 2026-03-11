import Testing
@testable import Mistty

struct SSHConfigServiceTests {
    @Test func parsesHostEntries() {
        let config = """
        Host myserver
            HostName 192.168.1.1
            User admin

        Host dev
            HostName dev.example.com
        """
        let hosts = SSHConfigService.parse(config)
        #expect(hosts.count == 2)
        #expect(hosts[0].alias == "myserver")
        #expect(hosts[1].alias == "dev")
    }

    @Test func ignoresWildcardHosts() {
        let config = "Host *\n    ServerAliveInterval 60\n"
        let hosts = SSHConfigService.parse(config)
        #expect(hosts.isEmpty)
    }

    @Test func capturesHostName() {
        let config = "Host mybox\n    HostName 10.0.0.1\n"
        let hosts = SSHConfigService.parse(config)
        #expect(hosts[0].hostname == "10.0.0.1")
    }

    @Test func emptyConfigReturnsEmpty() {
        #expect(SSHConfigService.parse("").isEmpty)
    }
}
