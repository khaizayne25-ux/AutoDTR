import 'dotenv/config';
import express from 'express';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {GoogleGenAI, Type} from '@google/genai';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PORT = Number(process.env.PORT) || 3000;
const ALLOWED_MIME_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);

interface ExtractedTimestampItem {
  time_24h: string;
  original_text: string;
  panel_position: string;
  confidence: 'high' | 'medium' | 'low';
}

interface ExtractionPayload {
  log_date: string | null;
  timestamps: ExtractedTimestampItem[];
  time_in: string | null;
  break_out: string | null;
  break_in: string | null;
  time_out: string | null;
  notes: string;
}

function normalizeTime24h(raw: string | null | undefined): string | null {
  if (!raw || typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  const match = trimmed.match(/^([01]?\d|2[0-3]):([0-5]\d)$/);
  if (!match) return null;
  return `${match[1].padStart(2, '0')}:${match[2]}`;
}

function mapSortedTimestamps(
  items: ExtractedTimestampItem[],
): Pick<ExtractionPayload, 'time_in' | 'break_out' | 'break_in' | 'time_out'> {
  const validSorted = items
    .map((item) => normalizeTime24h(item.time_24h))
    .filter((t): t is string => t !== null)
    .sort((a, b) => a.localeCompare(b));

  // Deduplicate identical minute stamps caused by overlapping crops
  const unique: string[] = [];
  for (const t of validSorted) {
    if (unique[unique.length - 1] !== t) {
      unique.push(t);
    }
  }

  if (unique.length === 0) {
    return {time_in: null, break_out: null, break_in: null, time_out: null};
  }
  if (unique.length === 1) {
    return {time_in: unique[0], break_out: null, break_in: null, time_out: null};
  }
  if (unique.length === 2) {
    return {time_in: unique[0], break_out: null, break_in: null, time_out: unique[1]};
  }
  if (unique.length === 3) {
    return {time_in: unique[0], break_out: unique[1], break_in: null, time_out: unique[2]};
  }
  return {
    time_in: unique[0],
    break_out: unique[1],
    break_in: unique[2],
    time_out: unique[unique.length - 1],
  };
}

async function startServer() {
  const app = express();
  app.use(express.json({limit: '4mb'}));

  app.get('/api/health', (_req, res) => {
    const apiKey = process.env.GEMINI_API_KEY || process.env.VITE_GEMINI_API_KEY;
    res.json({
      ok: true,
      geminiConfigured: Boolean(apiKey && !apiKey.startsWith('MY_GEMINI')),
    });
  });

  app.post('/api/extract-timestamps', async (req, res) => {
    try {
      const {imageBase64, mimeType} = req.body ?? {};
      if (typeof imageBase64 !== 'string' || !imageBase64.trim()) {
        res.status(400).json({error: 'Missing imageBase64 payload.'});
        return;
      }

      const safeMime =
        typeof mimeType === 'string' && ALLOWED_MIME_TYPES.has(mimeType)
          ? mimeType
          : 'image/jpeg';

      // Strip optional data URL prefix
      const cleanBase64 = imageBase64.replace(/^data:image\/[a-zA-Z0-9+.-]+;base64,/, '');
      if (cleanBase64.length > 3_000_000) {
        res.status(413).json({error: 'Image payload exceeds maximum size limit.'});
        return;
      }

      const apiKey = process.env.GEMINI_API_KEY || process.env.VITE_GEMINI_API_KEY;
      if (!apiKey || apiKey.startsWith('MY_GEMINI')) {
        res.status(503).json({
          error:
            'Gemini API key is not configured on the server. Set GEMINI_API_KEY in Secrets or VITE_GEMINI_API_KEY in .env.',
        });
        return;
      }

      const ai = new GoogleGenAI({
        apiKey,
        httpOptions: {
          headers: {
            'User-Agent': 'aistudio-build',
          },
        },
      });

      const prompt = [
        'You are an optical timestamp extraction engine for an employee Daily Time Record (DTR) verification system.',
        'Inspect this uploaded image, which may be a single timestamped photo OR a multi-panel photo collage (2 to 4 panels).',
        '1. Detect every visible date and time watermark, camera timestamp overlay, or digital wall clock.',
        '2. Convert every detected time into strict 24-hour HH:MM format (e.g., "07:58", "12:03", "13:01", "17:06").',
        '3. Extract the primary date in YYYY-MM-DD format if visible (if multiple dates appear, use the primary workday date; return null if no date is visible).',
        '4. Sort all detected timestamps chronologically from earliest to latest.',
        '5. Map timestamps strictly by count:',
        '   - If 2 timestamps: assign earliest to time_in and latest to time_out (break_out and break_in null).',
        '   - If 4 timestamps: assign chronologically to time_in, break_out, break_in, time_out.',
        '   - If 3 timestamps: assign chronologically to time_in, break_out, time_out (break_in null).',
        '   - If 1 timestamp: assign to time_in.',
        'Return strictly valid JSON matching the schema.',
      ].join('\n');

      const response = await ai.models.generateContent({
        model: 'gemini-2.5-flash',
        contents: {
          parts: [
            {
              inlineData: {
                mimeType: safeMime,
                data: cleanBase64,
              },
            },
            {text: prompt},
          ],
        },
        config: {
          responseMimeType: 'application/json',
          responseSchema: {
            type: Type.OBJECT,
            properties: {
              log_date: {
                type: Type.STRING,
                nullable: true,
                description: 'Detected date in YYYY-MM-DD format, or null if not visible.',
              },
              timestamps: {
                type: Type.ARRAY,
                description: 'All detected timestamps sorted chronologically.',
                items: {
                  type: Type.OBJECT,
                  properties: {
                    time_24h: {
                      type: Type.STRING,
                      description: 'Time in 24-hour HH:MM format.',
                    },
                    original_text: {
                      type: Type.STRING,
                      description: 'Exact timestamp text read from the image.',
                    },
                    panel_position: {
                      type: Type.STRING,
                      description: 'Location in image (e.g. top-left, bottom-right, single).',
                    },
                    confidence: {
                      type: Type.STRING,
                      description: 'Confidence level: high, medium, or low.',
                    },
                  },
                  required: ['time_24h', 'original_text', 'panel_position', 'confidence'],
                },
              },
              time_in: {type: Type.STRING, nullable: true},
              break_out: {type: Type.STRING, nullable: true},
              break_in: {type: Type.STRING, nullable: true},
              time_out: {type: Type.STRING, nullable: true},
              notes: {
                type: Type.STRING,
                description: 'Brief summary of detected watermarks or clock readings.',
              },
            },
            required: ['timestamps', 'notes'],
          },
        },
      });

      const rawText = (response.text ?? '{}').trim();
      const parsed = JSON.parse(rawText) as Partial<ExtractionPayload>;
      const rawItems = Array.isArray(parsed.timestamps) ? parsed.timestamps : [];

      // Deterministic chronological mapping fallback + verification
      const mapped = mapSortedTimestamps(rawItems);
      const result: ExtractionPayload = {
        log_date:
          typeof parsed.log_date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(parsed.log_date)
            ? parsed.log_date
            : null,
        timestamps: rawItems.map((item) => ({
          time_24h: normalizeTime24h(item.time_24h) ?? item.time_24h ?? '',
          original_text: String(item.original_text ?? ''),
          panel_position: String(item.panel_position ?? 'single'),
          confidence:
            item.confidence === 'high' || item.confidence === 'medium' || item.confidence === 'low'
              ? item.confidence
              : 'medium',
        })),
        time_in: mapped.time_in ?? normalizeTime24h(parsed.time_in),
        break_out: mapped.break_out ?? normalizeTime24h(parsed.break_out),
        break_in: mapped.break_in ?? normalizeTime24h(parsed.break_in),
        time_out: mapped.time_out ?? normalizeTime24h(parsed.time_out),
        notes:
          typeof parsed.notes === 'string' && parsed.notes.trim()
            ? parsed.notes.trim()
            : `Extracted ${rawItems.length} timestamp(s) from image.`,
      };

      res.json(result);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to extract timestamps.';
      console.error('[AutoDTR by: Juan] Gemini extraction error:', message);
      res.status(500).json({error: message});
    }
  });

  if (process.env.NODE_ENV !== 'production') {
    const {createServer: createViteServer} = await import('vite');
    const vite = await createViteServer({
      server: {middlewareMode: true},
      appType: 'spa',
    });
    app.use(vite.middlewares);
  } else {
    const distDir = path.resolve(__dirname, 'dist');
    app.use(express.static(distDir));
    app.get('*', (_req, res) => {
      res.sendFile(path.join(distDir, 'index.html'));
    });
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`AutoDTR by: Juan server listening on http://localhost:${PORT}`);
  });
}

startServer().catch((err) => {
  console.error('Failed to start AutoDTR by: Juan server:', err);
  process.exit(1);
});
