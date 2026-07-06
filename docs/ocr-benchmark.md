# OCR-Engine-Benchmark (lokal, Apple Silicon)

Warum `paperless-ocr` **Apple Vision für gedruckte Dokumente** und einen **Gemma-4-Fallback
für Handschrift/Mathe** nutzt — und warum die viel-gehypten OCR-VLMs *nicht* als Haupt-Engine
taugen. Alle Messungen auf dem Mac (M1 Max, 32 GB), Juli 2026. Nur **lokale** Engines
(vertrauliche Dokumente — keine Cloud).

## Testkorpus

| Dokument | Typ | Ground Truth |
|---|---|---|
| RU ЖКХ-Rechnung | dichte Finanztabelle, digital-born (zu „Scan" gerastert) | exakt (PDF-Textlayer) |
| BVG-Formular | Druck + **blasse Bleistift-Handschrift** in Kästchen | Feld-Stichprobe |
| Mathe-Mitschrift | **handschriftliche** Vorlesung (∀, ∈, ℕ, Brüche) | Formel-Stichprobe |

**Metrik-Hinweis:** Primär ist **reihenfolge-unabhängiges Word-F1**. Naive Sequenz-Ähnlichkeit
und CER auf dem ganzen Dokument sind durch abweichende **Lesereihenfolge** verfälscht (z. B.
misst dieselbe RU-Seite 0.35 Sequenz-Ähnlichkeit, aber 0.95 Word-F1) — sie sind daher nur
Sekundärmetriken.

## Ergebnis 1 — dichte gedruckte Tabelle (RU), Word-F1 vs. exakte GT

| Engine | F1 | Zeit | Peak-RAM | Bemerkung |
|---|---|---|---|---|
| **Apple Vision (ocrmac, direkt)** | **0.955** | **2 s** | **~200 MB** | zeilenweise, kein Loop, liefert Bboxes |
| docling + ocrmac | 0.934 | 15 s | 1.3 GB | wie Vision + Markdown-Struktur, aber 7× langsamer |
| docling + easyocr | 0.812 | 24 s | 1.6 GB | schwächer; Kyrillisch nur mit Englisch mischbar |
| DeepSeek-OCR (transformers/MPS) | Prec 0.97 | 424 s | 19.5 GB | beste Markdown-Tabelle, aber unbrauchbar langsam |
| Unlimited-OCR (Baidu, MLX int8) | 0.53 | 24 s | 4 GB | kein Loop, native Bboxes; Russisch-Genauigkeit int8 mäßig |
| GLM-OCR (docling VLM) | 0.47 | 86 s | 3.3 GB | **Loop** („0.00 0.00…") |
| PaddleOCR-VL-4bit | 0.16 | 35 s | 1.4 GB | Header top, dann **Loop** |
| granite-docling-MLX | 0.15 | 67 s | 1.6 GB | **Loop** |
| **Gemma-4** (`main`) | **0.075** | 103 s | =main | **Loop** — selbst der 26B kippt |

**→ Auf dichten Tabellen loopen fast alle generativen VLMs. Zeilenbasiertes Apple Vision
gewinnt klar — schnell, winzig, textlayer-tauglich.**

## Ergebnis 2 — Handschrift (BVG-Formular, Mathe-Mitschrift)

Genau umgekehrt: **Gemma-4 gewinnt deutlich.**
- Mathe: perfektes LaTeX (`$\forall k,n \in \mathbb{N}$`, `$\mathbb{Z}=(\mathbb{N}\times\mathbb{N})/\sim$`),
  vollständige Struktur (17 s).
- BVG: liest die Bleistift-Kundennummer + das Stempeldatum zuverlässig.
- **Apple Vision, PaddleOCR-VL, docling** verfehlen die blasse Handschrift **komplett** und
  zerbrechen Mathe-Symbole (∀→„Kk", ℕ→„IN").

## Ergebnis 3 — die neuen OCR-VLMs (DeepSeek-OCR-2, Unlimited-OCR)

- **DeepSeek-OCR** (Original): einziger VLM mit sauberer Markdown-Tabelle auf dem dichten Doc
  (Prec 0.97), aber **424 s/Seite + 19.5 GB** über transformers/MPS → unpraktisch. **DeepSeek-OCR-2
  (3B) MLX lädt nicht** in mlx-vlm 0.6.3 (Custom-Processor nicht auflösbar).
- **Unlimited-OCR** (Baidu, MIT, `sahilchachra/unlimited-ocr-8bit-mlx`): **praktikabel** (24 s,
  4 GB, MLX), liest dichte Tabellen **ohne Loop**, mit **nativen Grounding-Bboxes** → aus denen
  ließ sich ein durchsuchbares PDF bauen (verifiziert). Aber: Russisch-Genauigkeit int8 nur ~0.53
  (mxfp8 wurde *schlechter*, halluziniert), und mlx-vlm 0.6.3 gibt Nicht-ASCII als Byte-BPE aus
  (Postfix nötig). Für den **Textlayer** schlägt Apple Vision es klar (0.955 vs 0.53, 12×
  schneller); sein einziger Vorteil ist Struktur, die für RAG bereits **docling+ocrmac** (0.934)
  liefert. **→ Keine eigene Route** in `paperless-ocr`; ggf. später für Langdok-RAG (32k, flat-KV).

## Entscheidung (in `paperless-ocr` umgesetzt)

**Routing nach Dokumenttyp, ein großes Modell:**
1. **Gedruckt / Tabellen / Rechnungen → Apple Vision** (Textlayer mit Wort-Bboxes).
2. **Handschrift / Mathe / komplex → Gemma-4** (`main`, schon geladen — kein 2. Modell). Ganzseiten-
   Textschicht. Trigger: Tag `ocr:vlm` bzw. `_vlm`-Dateiname (zuverlässig) + Auto-Heuristik
   (Vision liest < `PAPERLESS_OCR_VLM_MIN_CHARS` Zeichen/Seite) als Sicherheitsnetz.
3. Digital-born PDFs → unverändert durchgereicht.

RAM-Fußnote (für Co-Residenz): Apple Vision ~200 MB, PaddleOCR ~1.4 GB und Unlimited-OCR ~4 GB
sind neben dem 26B-`main` lauffähig; DeepSeek-OCR (~19.5 GB) nur mit ausgebootetem `main`.
