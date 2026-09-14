// Cross-language contract check against the actually installed, Git-pinned JS SDK.
import { parseChatRequest } from '@handrail/ai-assistant';

try {
  parseChatRequest(JSON.parse(process.argv[2]));
  console.log('Valid shared ChatRequest');
} catch (error) {
  console.error(`${error.name}: ${error.path ?? 'request'}`);
  process.exitCode = 1;
}
