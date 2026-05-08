import { LLMPostProcessor } from "./llm-post-processor.js";
import { FakePostProcessor } from "./fake-post-processor.js";
import type { PostProcessor } from "./post-processor.js";

export type PostProcessorStrategy = "auto" | "fake" | "real";

function parseModelChain(value: string | undefined): string[] | undefined {
  const models = value
    ?.split(",")
    .map((model) => model.trim())
    .filter(Boolean);

  return models && models.length > 0 ? models : undefined;
}

export function createPostProcessor(strategy: PostProcessorStrategy): PostProcessor {
  const apiKey = (process.env.WALLEBRAIN_LLM_API_KEY ?? process.env.DEERAPI_KEY);
  const baseUrl = (process.env.WALLEBRAIN_LLM_BASE_URL ?? process.env.DEERAPI_BASE_URL);
  const modelChain = parseModelChain(process.env.WALLEBRAIN_LLM_MODELS);

  if (strategy === "fake") {
    return new FakePostProcessor();
  }

  if (strategy === "real") {
    if (!apiKey || !baseUrl) {
      throw new Error("WALLEBRAIN_LLM_API_KEY or WALLEBRAIN_LLM_BASE_URL is missing.");
    }

    return new LLMPostProcessor({
      apiKey,
      baseUrl,
      normalModelChain: modelChain,
      importantModelChain: modelChain,
    });
  }

  if (apiKey && baseUrl) {
    return new LLMPostProcessor({
      apiKey,
      baseUrl,
      normalModelChain: modelChain,
      importantModelChain: modelChain,
    });
  }

  return new FakePostProcessor();
}
