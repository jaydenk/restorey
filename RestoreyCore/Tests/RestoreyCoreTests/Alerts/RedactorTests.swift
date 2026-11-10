import Foundation
import Testing

@testable import RestoreyCore

struct RedactorTests {
    @Test func redactsLongestSecretFirst() {
        let r = Redactor(secrets: ["hunter", "hunter2-long"])
        #expect(r.redact("pw=hunter2-long end") == "pw=[redacted] end")
        #expect(r.redact("pw=hunter end") == "pw=[redacted] end")
    }

    @Test func redactsURLUserinfo() {
        let r = Redactor(secrets: [])
        #expect(r.redact("open https://user:pass@example.com/x failed") == "open https://[redacted]@example.com/x failed")
        #expect(r.redact("sftp://bob@host:22/repo") == "sftp://[redacted]@host:22/repo")
        #expect(r.redact("rest:http://u:p@10.0.0.1:8000/") == "rest:http://[redacted]@10.0.0.1:8000/")
        #expect(r.redact("no userinfo https://example.com/a@b") == "no userinfo https://example.com/a@b")
    }

    @Test func redactsCheckInURL() {
        let r = Redactor(secrets: [])
        let id = "5b2e8c3a-1111-2222-3333-444455556666"
        #expect(r.redact("POST https://hc-ping.com/\(id)/fail failed") == "POST https://hc-ping.com/[redacted] failed")
        #expect(r.redact("GET https://hc-ping.com/\(id)") == "GET https://hc-ping.com/[redacted]")
        #expect(r.redact("https://hc-ping.com/ping-key/slug?create=1 x") == "https://hc-ping.com/[redacted] x")

        let custom = Redactor(secrets: [], checkInURLs: ["https://checks.example.org/ping/abc-123"])
        #expect(custom.redact("see https://checks.example.org/ping/abc-123/start now") == "see https://checks.example.org/[redacted] now")
        #expect(custom.redact("https://other.example.org/ping/x") == "https://other.example.org/ping/x")
    }

    @Test func emptySecretIgnored() {
        let r = Redactor(secrets: ["", "   ", "\n\t"])
        #expect(r.redact("nothing to hide here") == "nothing to hide here")
    }

    @Test func redactsPercentEncodedForm() {
        let r = Redactor(secrets: ["p@ss/w rd"])
        #expect(r.redact("url https://h/?k=p%40ss%2Fw%20rd end") == "url https://h/?k=[redacted] end")
        #expect(r.redact("raw p@ss/w rd") == "raw [redacted]")
    }

    @Test func redactsEverySecretOccurrence() {
        let r = Redactor(secrets: ["abc123"])
        #expect(r.redact("abc123 and abc123") == "[redacted] and [redacted]")
    }

    @Test func secretsWithRegexCharactersAreLiteral() {
        let r = Redactor(secrets: ["a.b*c$1"])
        #expect(r.redact("x a.b*c$1 y aXb c") == "x [redacted] y aXb c")
    }

    @Test func redactsTrimmedFormOfPaddedSecret() {
        let r = Redactor(secrets: ["  hunter2\n"])
        #expect(r.redact("pw=hunter2 end") == "pw=[redacted] end")
        #expect(r.redact("url ?k=hunter2") == "url ?k=[redacted]")
    }

    @Test func redactsLowercasePercentAndFormEncoding() {
        let r = Redactor(secrets: ["p@ss/w rd"])
        #expect(r.redact("k=p%40ss%2fw%20rd") == "k=[redacted]")
        #expect(r.redact("k=p%40ss%2Fw+rd") == "k=[redacted]")
    }

    @Test func redactsBase64Forms() {
        let secret = "a>>>b???c"
        let std = Data(secret.utf8).base64EncodedString()
        let url = std.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(std != url)
        let r = Redactor(secrets: [secret])
        #expect(r.redact("Authorization: Basic \(std)") == "Authorization: Basic [redacted]")
        #expect(r.redact("token \(url)") == "token [redacted]")
    }

    @Test func userinfoConsumesToLastAtBeforeHost() {
        let r = Redactor(secrets: [])
        #expect(r.redact("https://u:p@ss@host/x") == "https://[redacted]@host/x")
    }

    @Test func checkInPathStopsAtJSONDelimiters() {
        let r = Redactor(secrets: [])
        #expect(
            r.redact(#"{"url":"https://hc-ping.com/abc-123","x":1}"#)
                == #"{"url":"https://hc-ping.com/[redacted]","x":1}"#)
        #expect(r.redact("(https://hc-ping.com/abc-123), then") == "(https://hc-ping.com/[redacted]), then")
    }

    @Test func checkInPassRunsBeforeUserinfoPass() {
        let r = Redactor(secrets: [])
        #expect(r.redact("https://x@hc-ping.com/abc-123/fail") == "https://[redacted]@hc-ping.com/[redacted]")
    }

    @Test func replacementIsSinglePass() {
        let r = Redactor(secrets: ["act"])
        #expect(r.redact("act act") == "[redacted] [redacted]")
        #expect(Redactor(secrets: ["d"]).redact("d red") == "[redacted] re[redacted]")
    }
}
