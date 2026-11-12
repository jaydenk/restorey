import Foundation
import Testing
@testable import RestoreyCore

struct FormValidationTests {
    // MARK: Bucket

    @Test(arguments: ["my-bucket", "backups.2026", "abc", "a1b2c3", String(repeating: "a", count: 63)])
    func validBucketsPass(_ bucket: String) {
        #expect(FormValidation.bucket(bucket) == nil)
    }

    @Test(arguments: ["MyBucket", "my bucket", "my-Bucket", "tab\tbucket"])
    func upperCaseAndSpacesAreRefusedWithTheBriefsSentence(_ bucket: String) {
        #expect(FormValidation.bucket(bucket) == "Bucket names are lower case, without spaces.")
    }

    @Test func spacesAroundABucketArePastingSlipsNotErrors() {
        #expect(FormValidation.bucket(" my-bucket ") == nil)
    }

    @Test func emptyAndMisshapenBucketsAreRefused() {
        #expect(FormValidation.bucket("") == "Enter the bucket name.")
        #expect(FormValidation.bucket("   ") == "Enter the bucket name.")
        #expect(FormValidation.bucket("ab") == "Bucket names are 3 to 63 characters of lower case letters, numbers, hyphens and dots.")
        #expect(FormValidation.bucket(String(repeating: "a", count: 64))
            == "Bucket names are 3 to 63 characters of lower case letters, numbers, hyphens and dots.")
        #expect(FormValidation.bucket("my_bucket")
            == "Bucket names are 3 to 63 characters of lower case letters, numbers, hyphens and dots.")
        #expect(FormValidation.bucket("a/b/c")
            == "Bucket names are 3 to 63 characters of lower case letters, numbers, hyphens and dots.")
    }

    // MARK: Endpoint

    @Test func anEndpointWithoutASchemeGetsHTTPS() {
        #expect(FormValidation.endpoint("s3.us-west-004.backblazeb2.com") == nil)
        #expect(FormValidation.normalisedEndpoint("s3.us-west-004.backblazeb2.com") == "https://s3.us-west-004.backblazeb2.com")
        #expect(FormValidation.normalisedEndpoint("  s3.example.com:9000/ ") == "https://s3.example.com:9000")
    }

    @Test func httpAndHTTPSEndpointsAreKept() {
        #expect(FormValidation.endpoint("https://s3.example.com") == nil)
        #expect(FormValidation.endpoint("http://nas.local:9000") == nil)
        #expect(FormValidation.normalisedEndpoint("http://nas.local:9000") == "http://nas.local:9000")
        #expect(FormValidation.normalisedEndpoint("HTTPS://S3.example.com/") == "https://s3.example.com")
    }

    @Test func otherSchemesAndJunkAreRefused() {
        #expect(FormValidation.endpoint("ftp://x") == "The endpoint must start with https:// or http://.")
        #expect(FormValidation.endpoint("s3://bucket") == "The endpoint must start with https:// or http://.")
        #expect(FormValidation.endpoint("") == "Enter the endpoint.")
        #expect(FormValidation.endpoint("https://") == "That endpoint isn't a web address.")
        #expect(FormValidation.endpoint("https://exa mple.com") == "That endpoint isn't a web address.")
        #expect(FormValidation.normalisedEndpoint("ftp://x") == nil)
        #expect(FormValidation.normalisedEndpoint("") == nil)
    }

    // MARK: Host label

    @Test func hostLabelMustHaveSomethingInIt() {
        #expect(FormValidation.hostLabel("Jayden's MacBook") == nil)
        #expect(FormValidation.hostLabel("") == "The host label can't be empty.")
        #expect(FormValidation.hostLabel("  \n ") == "The host label can't be empty.")
        #expect(FormValidation.hostLabel("two\nlines") == "The host label must be on one line.")
    }

    // MARK: Upload limit (MB/s typed, KiB/s stored)

    @Test func emptyUploadLimitMeansNone() {
        #expect(FormValidation.uploadLimit("") == .success(nil))
        #expect(FormValidation.uploadLimit("   ") == .success(nil))
    }

    @Test func uploadLimitConvertsMegabytesToKiB() {
        #expect(FormValidation.uploadLimit("5") == .success(5120))
        #expect(FormValidation.uploadLimit("1.5") == .success(1536))
        #expect(FormValidation.uploadLimit(" 2 ") == .success(2048))
        #expect(FormValidation.uploadLimit("0.5") == .success(512))
    }

    @Test(arguments: ["0", "-1", "0.0", "-0.5", "0.0001"])
    func uploadLimitMustBeMoreThanZero(_ text: String) {
        #expect(FormValidation.uploadLimit(text) == .failure("The upload limit must be more than 0 MB/s. Leave it empty for no limit."))
    }

    @Test(arguments: ["fast", "5 MB", "1,5", "1.2.3", "NaN", "inf", "99999999999999999999999"])
    func uploadLimitMustBeANumber(_ text: String) {
        #expect(FormValidation.uploadLimit(text) == .failure("Enter the limit as a number of MB/s, such as 5 or 1.5."))
    }

    // MARK: File types

    @Test func typedFileTypesAreNormalisedAndDeduplicated() {
        let result = FormValidation.addingFileTypes("DMG, iso  tar.gz\nDMG", to: ["zip", "iso"])
        #expect(result.types == ["zip", "iso", "dmg", "tar.gz"])
        #expect(result.rejected.isEmpty)
    }

    @Test func invalidFileTypesAreReportedAndNotAdded() {
        let result = FormValidation.addingFileTypes("dmg .iso *.zip a/b", to: [])
        #expect(result.types == ["dmg"])
        #expect(result.rejected == [".iso", "*.zip", "a/b"])
        #expect(FormValidation.fileTypeProblem == "Give the extension alone, such as dmg or tar.gz, with no leading dot, slash or wildcard.")
    }

    @Test func nothingTypedAddsNothing() {
        let result = FormValidation.addingFileTypes("  , ,\n", to: ["dmg"])
        #expect(result.types == ["dmg"])
        #expect(result.rejected.isEmpty)
    }
}
