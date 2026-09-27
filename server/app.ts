// Vercel entry point (project `skipass-server`). Vercel runs the default-exported Hono app of a
// file that imports `hono`, found at a fixed path (https://vercel.com/docs/frameworks/backend/hono,
// "Exporting the Hono application"); this is that file. The Cloudflare Worker entry is
// src/index.ts (excluded from Vercel uploads by .vercelignore); both serve the app in src/api.ts.
import { Hono } from 'hono'
import { createVercelApp } from './src/vercel.js'

// Node's `process.env` (Vercel Functions run on Node.js); declared here to avoid @types/node.
declare const process: { env: Record<string, string | undefined> }

const app = new Hono()
app.route('/', createVercelApp(process.env))

export default app
