// Vercel Function (Node.js runtime, Web-standard `fetch` export:
// https://vercel.com/docs/functions/runtimes/node-js#create-a-node.js-function-in-/api).
import { handleStatus } from '../lib/handlers.js'

export default {
  fetch(request: Request): Promise<Response> {
    return handleStatus(request, process.env)
  },
}
