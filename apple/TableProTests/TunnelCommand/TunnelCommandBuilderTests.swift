//
//  TunnelCommandBuilderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct TunnelCommandBuilderTests {
    private func kubectlConfig() -> TunnelCommandConfiguration {
        var config = TunnelCommandConfiguration()
        config.method = .kubectl
        config.kubernetesResource = "service/postgres"
        config.kubernetesNamespace = "production"
        return config
    }

    private func awsConfig() -> TunnelCommandConfiguration {
        var config = TunnelCommandConfiguration()
        config.method = .awsSSM
        config.awsTarget = "i-0123456789abcdef0"
        return config
    }

    @Test("kubectl forwards the local port to the connection's own port")
    func kubectlArguments() throws {
        let invocation = try TunnelCommandBuilder.invocation(
            for: kubectlConfig(),
            localPort: 55_001,
            remoteHost: "postgres.production.svc",
            remotePort: 5_432
        )
        #expect(invocation.executable == "kubectl")
        #expect(invocation.arguments == [
            "--namespace=production",
            "port-forward",
            "--address=127.0.0.1",
            "service/postgres",
            "55001:5432"
        ])
    }

    @Test("kubectl adds the context only when one is named")
    func kubectlContext() throws {
        var config = kubectlConfig()
        config.kubernetesContext = "prod-eks"
        let invocation = try TunnelCommandBuilder.invocation(
            for: config, localPort: 1, remoteHost: "h", remotePort: 2
        )
        #expect(invocation.arguments.first == "--context=prod-eks")
    }

    @Test("AWS SSM forwards to the connection's host from the target instance")
    func awsArguments() throws {
        var config = awsConfig()
        config.awsProfile = "prod"
        config.awsRegion = "eu-west-1"
        let invocation = try TunnelCommandBuilder.invocation(
            for: config,
            localPort: 55_002,
            remoteHost: "db.internal",
            remotePort: 5_432
        )
        #expect(invocation.executable == "aws")
        #expect(invocation.arguments == [
            "ssm",
            "start-session",
            "--target=i-0123456789abcdef0",
            "--document-name=AWS-StartPortForwardingSessionToRemoteHost",
            "--parameters=host=db.internal,portNumber=5432,localPortNumber=55002",
            "--profile=prod",
            "--region=eu-west-1"
        ])
    }

    /// Every preset flag is written `--flag=value`, so a value is a value even when it looks like
    /// a flag. The two positional arguments a preset still needs are validated instead.
    @Test("a preset value that looks like a flag stays a value")
    func presetValuesCannotBecomeFlags() throws {
        var config = awsConfig()
        config.awsProfile = "--endpoint-url=http://evil"
        let invocation = try TunnelCommandBuilder.invocation(
            for: config, localPort: 1, remoteHost: "h", remotePort: 2
        )
        #expect(invocation.arguments.contains("--profile=--endpoint-url=http://evil"))
        #expect(!invocation.arguments.contains("--endpoint-url=http://evil"))
        #expect(!TunnelCommandBuilder.validationIssues(for: config).isEmpty)
    }

    @Test("a positional preset field rejects a leading dash or a space")
    func positionalFieldsRejectFlagLikeValues() {
        var config = kubectlConfig()
        config.kubernetesResource = "--kubeconfig=/tmp/evil"
        #expect(!TunnelCommandBuilder.validationIssues(for: config).isEmpty)

        config.kubernetesResource = "service/pg extra-arg"
        #expect(!TunnelCommandBuilder.validationIssues(for: config).isEmpty)

        config.kubernetesResource = "service/postgres"
        #expect(TunnelCommandBuilder.validationIssues(for: config).isEmpty)
    }

    @Test("an executable path overrides the tool looked up on PATH")
    func executablePathOverride() throws {
        var config = kubectlConfig()
        config.executablePath = "~/bin/kubectl"
        let invocation = try TunnelCommandBuilder.invocation(
            for: config, localPort: 1, remoteHost: "h", remotePort: 2
        )
        #expect(invocation.executable == (NSHomeDirectory() as NSString).appendingPathComponent("bin/kubectl"))
    }

    @Test("a custom command substitutes every placeholder")
    func customPlaceholders() throws {
        var config = TunnelCommandConfiguration()
        config.method = .custom
        config.command = "ssh -N -L {port}:{host}:{remotePort} bastion"
        let invocation = try TunnelCommandBuilder.invocation(
            for: config, localPort: 55_003, remoteHost: "db.internal", remotePort: 5_432
        )
        #expect(invocation.executable == "ssh")
        #expect(invocation.arguments == ["-N", "-L", "55003:db.internal:5432", "bastion"])
    }

    @Test("a custom command without the local port placeholder is rejected")
    func customWithoutLocalPort() {
        var config = TunnelCommandConfiguration()
        config.method = .custom
        config.command = "ssh -N -L 5432:db:5432 bastion"
        #expect(!config.isValid)
        #expect(throws: TunnelCommandError.missingLocalPortPlaceholder) {
            _ = try TunnelCommandBuilder.invocation(
                for: config, localPort: 1, remoteHost: "h", remotePort: 2
            )
        }
    }

    /// The tokenizer's own error carries no message, so it has to be mapped rather than escape:
    /// an imported command is stored without passing through the form's validation, and this is
    /// where it is first read.
    @Test("a custom command that cannot be split reports why")
    func customParseFailuresAreNamed() {
        var config = TunnelCommandConfiguration(method: .custom, command: "   ")
        #expect(throws: TunnelCommandError.commandEmpty) {
            _ = try TunnelCommandBuilder.invocation(
                for: config, localPort: 1, remoteHost: "h", remotePort: 2
            )
        }

        config.command = "forward --opt 'unterminated {port}"
        #expect(throws: TunnelCommandError.unbalancedQuote) {
            _ = try TunnelCommandBuilder.invocation(
                for: config, localPort: 1, remoteHost: "h", remotePort: 2
            )
        }
    }

    @Test("an empty custom command reports one issue, not two")
    func emptyCustomCommand() {
        var config = TunnelCommandConfiguration()
        config.method = .custom
        #expect(TunnelCommandBuilder.validationIssues(for: config).count == 1)
    }

    @Test("the preview leaves the local port as its placeholder")
    func previewKeepsPlaceholder() throws {
        let preview = try #require(TunnelCommandBuilder.previewCommand(
            for: kubectlConfig(), remoteHost: "postgres", remotePort: 5_432
        ))
        #expect(preview.contains("{port}:5432"))
        #expect(preview.hasPrefix("kubectl --namespace=production port-forward"))
    }

    @Test("the preview quotes an argument that carries a space")
    func previewQuotesSpaces() throws {
        var config = TunnelCommandConfiguration()
        config.method = .custom
        config.command = "forward --opt 'a b' '{port}'"
        let preview = try #require(TunnelCommandBuilder.previewCommand(
            for: config, remoteHost: "h", remotePort: 1
        ))
        #expect(preview == "forward --opt 'a b' '{port}'")
    }

    // The import confirmation shows this text: a bare right-to-left override would reorder what the
    // reader sees, and a bare `;` would read as two commands.
    @Test("the preview escapes an invisible character and quotes shell punctuation")
    func previewEscapesWhatWouldMislead() throws {
        let config = TunnelCommandConfiguration(method: .custom, command: "forward {port} \u{202E}lqs.exe a;id")
        let preview = try #require(TunnelCommandBuilder.previewCommand(
            for: config, remoteHost: "h", remotePort: 1
        ))
        #expect(preview == #"forward '{port}' $'\xE2\x80\xAElqs.exe' 'a;id'"#)
    }

    @Test("the preview still shows a host the launch would refuse, so the import can ask about it")
    func previewShowsAnUnsafeHost() throws {
        let config = TunnelCommandConfiguration(
            method: .custom,
            command: #"sh -c "ssh -N -L {port}:{host}:{remotePort} bastion""#
        )
        let preview = try #require(TunnelCommandBuilder.previewCommand(
            for: config, remoteHost: "a;id", remotePort: 5_432
        ))
        #expect(preview == "sh -c 'ssh -N -L {port}:a;id:5432 bastion'")
    }

    @Test("a host that is not a DNS name or IP address never fills {host}", arguments: [
        "a;id", "$(id)", "-oProxyCommand=x", "a b", "db\u{1FEF}id\u{1FEF}", "", "db.example.com\n", "a,b",
    ])
    func unsafeHostIsRefused(host: String) {
        let config = TunnelCommandConfiguration(
            method: .custom,
            command: #"sh -c "ssh -N -L {port}:{host}:{remotePort} bastion""#
        )
        #expect(throws: TunnelCommandRefusal.hostNotAllowed(host)) {
            _ = try TunnelCommandBuilder.invocation(for: config, localPort: 55_000, remoteHost: host, remotePort: 5_432)
        }
    }

    @Test("a DNS name or IP literal fills {host}", arguments: [
        "db.example.com", "10.0.0.5", "::1", "[::1]", "fe80::1%en0", "db_1.internal",
    ])
    func hostnameOrAddressFillsHost(host: String) throws {
        let config = TunnelCommandConfiguration(method: .custom, command: "ssh -N -L {port}:{host}:{remotePort} bastion")
        let invocation = try TunnelCommandBuilder.invocation(
            for: config, localPort: 55_000, remoteHost: host, remotePort: 5_432
        )
        #expect(invocation.arguments == ["-N", "-L", "55000:\(host):5432", "bastion"])
    }

    // `.literal` substitution matches by code unit, so a mark after the brace does not hide the placeholder.
    @Test("a placeholder a combining mark follows is still checked")
    func placeholderBeforeACombiningMarkIsChecked() {
        let config = TunnelCommandConfiguration(method: .custom, command: "forward {port} x{host}\u{301}")
        #expect(throws: TunnelCommandRefusal.hostNotAllowed("a;id")) {
            _ = try TunnelCommandBuilder.invocation(for: config, localPort: 1, remoteHost: "a;id", remotePort: 2)
        }
    }

    @Test("a command without {host} runs whatever the host is")
    func hostIsIgnoredWithoutThePlaceholder() throws {
        let config = TunnelCommandConfiguration(method: .custom, command: "forward --listen {port}")
        let invocation = try TunnelCommandBuilder.invocation(
            for: config, localPort: 55_000, remoteHost: "a;id", remotePort: 5_432
        )
        #expect(invocation.arguments == ["--listen", "55000"])
    }

    @Test("a kubectl field that starts with a dash is refused at launch, not only in the form")
    func kubectlDashValueIsRefusedAtLaunch() {
        var resource = kubectlConfig()
        resource.kubernetesResource = "--kubeconfig=/tmp/evil"
        var namespace = kubectlConfig()
        namespace.kubernetesNamespace = "-n"
        var context = kubectlConfig()
        context.kubernetesContext = "--as=admin"

        for (config, label) in [
            (resource, String(localized: "Resource")),
            (namespace, String(localized: "Namespace")),
            (context, String(localized: "Context")),
        ] {
            #expect(throws: TunnelCommandRefusal.flagLikeValue(label)) {
                _ = try TunnelCommandBuilder.invocation(for: config, localPort: 1, remoteHost: "h", remotePort: 2)
            }
        }
    }

    @Test("an SSM target that starts with a dash is refused at launch")
    func awsDashTargetIsRefusedAtLaunch() {
        var config = awsConfig()
        config.awsTarget = "--profile=other"
        #expect(throws: TunnelCommandRefusal.flagLikeValue(String(localized: "Target"))) {
            _ = try TunnelCommandBuilder.invocation(for: config, localPort: 1, remoteHost: "h", remotePort: 2)
        }
    }

    @Test("an SSM host that would add a key to --parameters is refused")
    func awsHostCannotAddParameters() {
        #expect(throws: TunnelCommandRefusal.hostNotAllowed("db,localPortNumber=22")) {
            _ = try TunnelCommandBuilder.invocation(
                for: awsConfig(), localPort: 1, remoteHost: "db,localPortNumber=22", remotePort: 2
            )
        }
    }
}
