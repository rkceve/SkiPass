// Vercel Function (Node.js runtime, Web-standard `fetch` export:
// https://vercel.com/docs/functions/runtimes/node-js#create-a-node.js-function-in-/api).
import { handleSendCode } from '../lib/handlers.js'

export default {
  fetch(request: Request): Promise<Response> {
    return handleSendCode(request, process.env)
  },
}
