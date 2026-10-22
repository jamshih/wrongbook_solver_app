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

        print("PASS: legacy media, typed crop/figures, new-over-legacy precedence, and text-only requests")
    }
}
