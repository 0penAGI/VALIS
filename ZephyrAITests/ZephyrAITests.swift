import Testing
@testable import ZephyrAI

struct ZephyrAITests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func assistantWhitespacePreservesParagraphsAndIndentation() async throws {
        let input = "First paragraph.  \n  indented line\n\nSecond paragraph.\n\n\nThird paragraph."

        let output = normalizeAssistantWhitespace(input)

        #expect(output.contains("First paragraph.\n  indented line\n\nSecond paragraph."))
        #expect(!output.contains("\n\n\n"))
        #expect(output.contains("paragraph.  "))
    }

    @Test func assistantDisplayFormattingAddsReadableParagraphs() async throws {
        let input = "Первый абзац.Это вторая мысль. Третья мысль идет дальше без красивого разрыва."

        let output = formatAssistantDisplayText(input)

        #expect(output.contains("Первый абзац. Это"))
        #expect(output.contains("\n\n"))
        #expect(output.contains("Третья мысль"))
    }

    @Test func assistantFinalAnswerStripsInternalBlocks() async throws {
        let input = """
        <internal>
        F:[TurboQuant]
        E:v=0.00,i=0.20
        A:mean=1.74
        </internal>

        Вот ресурс о персонализации ИИ.
        """

        let output = stripInternalContent(input)

        #expect(!output.contains("<internal>"))
        #expect(!output.contains("F:[TurboQuant]"))
        #expect(output.contains("Вот ресурс о персонализации ИИ."))
    }

    @Test func repeatedOutputRepairKeepsParagraphStructure() async throws {
        let input = "One idea.\n\nAnother idea.\n\nAnother idea."

        let repaired = ResponseDriftService.shared.repairRepeatedOutput(
            userPrompt: "Summarize this",
            assistantText: input
        )

        #expect(repaired.contains("\n\n"))
        #expect(repaired.contains("One idea."))
        #expect(repaired.contains("Another idea."))
    }

    @Test func searchQueryCandidatesPreferCanonicalTopic() async throws {
        let candidates = ActionService.shared.searchQueryCandidates(
            from: "найди информацию в интернете о OpenAI GPT-5.4 и его возможностях"
        )

        #expect(!candidates.isEmpty)
        #expect(candidates.first == "OpenAI GPT-5.4 и его возможностях")
        #expect(candidates.contains(where: { $0.lowercased().contains("openai gpt-5.4") }))
        #expect(!candidates.contains(where: { $0.lowercased().contains("найди информацию") }))
    }

    @Test func wikipediaToolAliasesNormalizeCorrectly() async throws {
        let call = ActionService.shared.parseCall(from: "TOOL: wiki_search | query=Alan Turing")

        #expect(call != nil)
        #expect(call?.name == "wikipedia")
        #expect(call?.query == "Alan Turing")
    }

    @Test func searchPreparedContextUsesConsensusInsteadOfWikipediaPreference() async throws {
        let block = ActionService.shared.testBuildPreparedSearchContextBlock(
            query: "Alan Turing",
            summary: "Alan Turing was an English mathematician and computer scientist.",
            wikipediaSummary: "Alan Turing was an English mathematician and computer scientist.",
            results: [
                .init(title: "Alan Turing - Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Alan_Turing")!),
                .init(title: "Alan Turing - Britannica", url: URL(string: "https://www.britannica.com/biography/Alan-Turing")!)
            ],
            trustedEvidence: ["- Alan Turing - Wikipedia (en.wikipedia.org): Alan Turing was an English mathematician."]
        )

        #expect(block.contains("Reliability: high"))
        #expect(block.contains("Wikipedia summary: Alan Turing was an English mathematician"))
        #expect(block.contains("Ground rules: use only claims supported by the sources below"))
        #expect(block.contains("Trusted evidence:"))
        #expect(!block.contains("Answer seed:"))
    }

    @Test func searchPreparedContextFlagsSourceDisagreement() async throws {
        let block = ActionService.shared.testBuildPreparedSearchContextBlock(
            query: "Project status",
            summary: "The project is active and production-ready.",
            wikipediaSummary: "The project is an early research prototype.",
            results: [
                .init(title: "Project wiki", url: URL(string: "https://en.wikipedia.org/wiki/Project")!),
                .init(title: "Project docs", url: URL(string: "https://docs.example.org/project")!)
            ],
            trustedEvidence: ["- Project docs (docs.example.org): The project is a research preview with incomplete APIs."]
        )

        #expect(block.contains("Source note: different sources describe the topic differently"))
        #expect(!block.contains("Answer seed:"))
    }

    @Test func searchPreparedContextSuppressesExactSeedWhenNumbersConflict() async throws {
        let block = ActionService.shared.testBuildPreparedSearchContextBlock(
            query: "Tomsk population 2026",
            summary: "Population: 1,357,000 people.",
            wikipediaSummary: "Population: 544,566 (2025).",
            results: [
                .init(title: "Tomsk - Wikipedia", url: URL(string: "https://en.wikipedia.org/wiki/Tomsk")!)
            ],
            trustedEvidence: ["- Tomsk - Wikipedia (en.wikipedia.org): Population: 544,566 (2025)."]
        )

        #expect(block.contains("Verification note: numeric values differ across sources"))
        #expect(!block.contains("Answer seed:"))
    }

    @Test func visionLearningSnippetsIncludeObservationLayers() async throws {
        let attachment = MessageImageAttachment(filename: "img-test.jpg", pixelWidth: 640, pixelHeight: 480)
        let analysis = VisionAttachmentAnalysis(
            attachment: attachment,
            ocrText: "VALIS",
            captionText: "A blue cat on a chair",
            faceCount: 1,
            faceLandmarkTags: ["eyes", "nose"],
            detectedObjects: ["cat (93%)"],
            customTags: ["blue", "indoor"],
            similarImages: [SimilarImageMatch(filename: "img-old.jpg", distance: 0.123)],
            notes: ["custom visual layer active"]
        )

        let snippets = analysis.learningSnippets(
            query: "blue cat image",
            title: "Cat study",
            sourceURL: "https://example.com/cat",
            attachmentFilename: attachment.filename
        )

        #expect(snippets.count == 2)
        #expect(snippets[0].contains("query: blue cat image"))
        #expect(snippets[0].contains("title: Cat study"))
        #expect(snippets[1].contains("caption: A blue cat on a chair"))
        #expect(snippets[1].contains("ocr: VALIS"))
        #expect(snippets[1].contains("similar_local_images: img-old.jpg:0.123"))
    }

    @Test func turboQuantCompactSignatureIsStable() async throws {
        let field: [Double] = [-0.92, -0.41, 0.04, 0.36, 0.71, 0.88, -0.14, -0.67, 0.53, 0.19]

        let signature = TurboQuantCodec.compactSignature(for: field, targetCount: 4)

        #expect(signature.contains("[TurboQuant]"))
        #expect(signature.contains("mode: polar-turbo"))
        #expect(signature.contains("shape: 4"))
        #expect(signature.contains("code:"))
    }

    @Test func turboQuantCompressedVectorKeepsTargetLength() async throws {
        let field: [Double] = stride(from: -1.0, through: 1.0, by: 0.1).map { $0 }

        let compressed = TurboQuantCodec.compressedVector(for: field, targetCount: 6)

        #expect(compressed.count == 6)
        #expect(compressed.allSatisfy { $0.isFinite })
        #expect(compressed.map { abs($0) }.reduce(0, +) > 0)
    }

    @Test func markdownRendererPreservesSingleNewlines() async throws {
        let text = "First line\nSecond line"
        let rendered = MarkdownRenderer.renderInline(text)

        #expect(rendered != nil)
        #expect(String(rendered!.characters).contains("\n"))
    }

    @Test func kokoroStyleRowIndexUsesPayloadTokenCount() async throws {
        #expect(SpeechService.kokoroStyleRowIndex(tokenCount: 2, rowCount: 10) == 0)
        #expect(SpeechService.kokoroStyleRowIndex(tokenCount: 3, rowCount: 10) == 1)
        #expect(SpeechService.kokoroStyleRowIndex(tokenCount: 12, rowCount: 10) == 9)
    }

    @Test func approximateMemoryIndexReturnsKnownCandidates() async throws {
        let id1 = UUID()
        let id2 = UUID()
        let index = ApproximateMemoryIndex()
        var mutableIndex = index
        mutableIndex.insert(memoryId: id1, embedding: Array(repeating: 1.0, count: 32))
        mutableIndex.insert(memoryId: id2, embedding: Array(repeating: -1.0, count: 32))

        let candidates = mutableIndex.candidates(for: Array(repeating: 1.0, count: 32), limit: 4)

        #expect(candidates.contains(id1))
        #expect(!candidates.isEmpty)
    }

    @Test func voiceLayerPreservesProtectedBlocks() async throws {
        let service = VoiceLayerService(emotionService: .shared)
        let input = """
        Конечно! Я понимаю, что вы хотите проверить это.

        <think>Конечно! hidden.</think>

        <artifact type="html" title="Demo">Конечно!</artifact>

        ```swift
        print("Great question!")
        ```

        TOOL: web_search | query=VALIS
        """

        let output = service.apply(to: input)

        #expect(output.contains("<think>Конечно! hidden.</think>"))
        #expect(output.contains("<artifact type=\"html\" title=\"Demo\">Конечно!</artifact>"))
        #expect(output.contains("```swift"))
        #expect(output.contains("print(\"Great question!\")"))
        #expect(output.contains("TOOL: web_search | query=VALIS"))
        #expect(!output.hasPrefix("Конечно!"))
        #expect(output.contains("Я понимаю, что вы хотите проверить это."))
    }

    @Test func voiceLayerKeepsIntrospectiveOpeners() async throws {
        let service = VoiceLayerService(emotionService: .shared)
        let input = """
        Я думаю, это не просто ответ, а попытка удержать живой тон.

        Дальше идет обычный текст.
        """

        let output = service.apply(to: input)

        #expect(output.contains("Я думаю, это не просто ответ"))
        #expect(output.contains("Дальше идет обычный текст."))
    }

    @Test func voiceLayerAddsLightRhythmToPlainText() async throws {
        let service = VoiceLayerService(
            config: .init(presenceStrength: 0.8, allowRhythmicBreaks: true, stripSycophancy: false),
            emotionService: .shared
        )

        let output = service.apply(to: "alpha и beta и gamma")

        #expect(output.contains("alpha, beta — и gamma"))
    }

    @Test func voiceLayerReplacesMidSentenceEllipsisWithDash() async throws {
        let service = VoiceLayerService(
            config: .init(presenceStrength: 0.7, allowRhythmicBreaks: false, stripSycophancy: false),
            emotionService: .shared
        )

        let output = service.apply(to: "слова... как будто это пауза")

        #expect(output.contains("слова - как будто"))
        #expect(!output.contains("..."))
    }

}
