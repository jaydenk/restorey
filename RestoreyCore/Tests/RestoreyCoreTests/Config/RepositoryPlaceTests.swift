import Foundation
import Testing
@testable import RestoreyCore

/// Where a plan backs up, for the symbol beside it in Settings → Plans (Task 17c fix round 1, review M6): a cloud
/// storage service, another machine (a server on the network), or this Mac.
struct RepositoryPlaceTests {
    @Test func cloudStorageServicesAreTheCloud() {
        let b2 = Repository.s3(S3Location(
            provider: .b2, endpoint: URL(string: "https://s3.us-west-004.backblazeb2.com")!, bucket: "b", prefix: ""))
        #expect(b2.place == .cloud)
        for location in ["b2:bucket:mac", "s3:s3.amazonaws.com/bucket", "azure:container:/", "gs:bucket:/",
                         "swift:container:/", "rclone:remote:backups"] {
            #expect(Repository.raw(repository: location, environmentNames: []).place == .cloud, "\(location)")
        }
    }

    @Test func aServerOnTheNetworkIsAServer() {
        for location in ["sftp:user@nas.local:/srv/restic", "rest:https://backup.lan:8000/mac",
                         "unknown:somewhere"] {
            #expect(Repository.raw(repository: location, environmentNames: []).place == .server, "\(location)")
        }
    }

    @Test func aFolderOrDriveIsThisMac() {
        for location in ["/Volumes/Backup/restic", "local:/Volumes/Backup/restic", "../restic", "restic"] {
            #expect(Repository.raw(repository: location, environmentNames: []).place == .thisMac, "\(location)")
        }
    }
}
