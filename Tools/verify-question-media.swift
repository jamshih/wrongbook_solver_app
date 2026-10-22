import Foundation

@main
struct QuestionMediaFixtureChecks {
    static func main() throws {
        let decoder = JSONDecoder()

        // Existing production requests must remain readable and cannot be misidentified
        // as a precise crop when the API only returns a source-page figure reference.
        let legacy = """
        {
          "id": "12345678-1234-1234-1234-123456789abc",
          "status": "queued", "subject": "math", "stem": "Legacy question",
          "figure_refs": [{"bucket":"wrongbook-images","path":"student/page.jpg","signedURL":"https://example.test/page","label":"原圖"}]
        }
        """
        let legacyRequest = try decoder.decode(SolverRequest.self, from: Data(legacy.utf8))
        precondition(legacyRequest.displayMedia.count == 1)
        precondition(!legacyRequest.displayMedia[0].isOriginalCrop)
        precondition(!legacyRequest.displayMedia[0].isExtractedFigure)
        precondition(legacyRequest.displayMedia[0].id == legacyRequest.displayMedia[0].id)

        // New snapshots take precedence over the legacy aliases, avoiding duplicate images.
        let newSnapshot = """
        {
          "id": "12345678-1234-1234-1234-123456789abc",
          "status": "claimed", "subject": "biology", "stem": "What does this chart show?",
          "figure_refs": [{"path":"student/page.jpg","signedURL":"https://example.test/page"}],
          "question_media": [
            {"kind":"extracted_figure","bucket":"wrongbook-images","path":"student/diagram-2.png","signedURL":"https://example.test/figure2","display_order":2,"label":"Figure 2"},
            {"kind":"original_selected_crop","bucket":"wrongbook-images","path":"student/crop.png","signedURL":"https://example.test/crop","display_order":0,"label":"Selected crop"},
            {"kind":"chart","bucket":"wrongbook-images","path":"student/chart-1.png","signedURL":"https://example.test/chart","display_order":1,"label":"Chart 1"}
          ]
        }
        """
        let latest = try decoder.decode(SolverRequest.self, from: Data(newSnapshot.utf8))
        precondition(latest.displayMedia.count == 3)
        precondition(latest.displayMedia.filter(\.isOriginalCrop).count == 1)
        precondition(latest.displayMedia.filter(\.isExtractedFigure).count == 2)
        precondition(latest.displayMedia.map(\.displayOrder) == [2, 0, 1])

        // Some questions have no image; the operator must still see their stem.
        let textOnly = """
        {"id":"12345678-1234-1234-1234-123456789abc","status":"queued","subject":"chemistry","stem":"No image"}
        """
        let text = try decoder.decode(SolverRequest.self, from: Data(textOnly.utf8))
        precondition(text.displayMedia.isEmpty)
        precondition(text.stem == "No image")

        var inbox = latest
        inbox.lastStudentMessageAt = Date(timeIntervalSince1970: 200)
        inbox.operatorReadAt = Date(timeIntervalSince1970: 100)
        precondition(inbox.hasUnreadStudentMessage)
        inbox.operatorReadAt = inbox.lastStudentMessageAt
        precondition(!inbox.hasUnreadStudentMessage)
        inbox.operatorReadAt = nil
        precondition(inbox.hasUnreadStudentMessage)
        let fixtureDefaults = UserDefaults(suiteName: "solver-retry-fixture-" + UUID().uuidString)!
        let requestID = latest.id
        let key = try SolverReplyIdentity.key(ownerID: "account-a", requestID: requestID, text: "follow up", images: [Data([1,2]), Data([3])])
        let uid = SolverReplyIdentity.clientUID(key: key, defaults: fixtureDefaults)
        precondition(SolverReplyIdentity.clientUID(key: key, defaults: fixtureDefaults) == uid)
        let otherOwnerKey = try SolverReplyIdentity.key(ownerID: "account-b", requestID: requestID, text: "follow up", images: [Data([1,2]), Data([3])])
        precondition(key != otherOwnerKey)
        let differentImagesKey = try SolverReplyIdentity.key(ownerID: "account-a", requestID: requestID, text: "follow up", images: [Data([1]), Data([2,3])])
        precondition(key != differentImagesKey)
        fixtureDefaults.removeObject(forKey: key)
        precondition(SolverReplyIdentity.clientUID(key: key, defaults: fixtureDefaults) != uid)
        fixtureDefaults.removeObject(forKey: key)
        let message = try decoder.decode(SolverMessage.self, from: Data("""
          {"id":"12345678-1234-4234-8234-123456789abc","request_id":"12345678-1234-1234-1234-123456789abc","author_kind":"student","body":"Follow up","attachments":[{"bucket":"wrongbook-human-solver","path":"students/account-a/request/photo.png","mimeType":"image/png","byteSize":100,"displayOrder":0,"signedURL":"https://example.test/signed"}]}
          """.utf8))
        precondition(message.authorKind == "student" && message.attachments?.count == 1)
        let nullSubject = try decoder.decode(SolverRequest.self, from: Data("""
          {"id":"12345678-1234-1234-1234-123456789abc","status":"answered","subject":null,"stem":"Legacy unclassified"}
          """.utf8))
        precondition(nullSubject.subject.isEmpty)
        print("PASS: student photo decoding, unread receipts, account-scoped retry identity and deliberate repeated messages")
        print("PASS: legacy media, typed crop/figures, new-over-legacy precedence, and text-only requests")
    }
}
