import { DeerApiPostProcessor } from "./deerapi-post-processor.js";
import { FakePostProcessor } from "./fake-post-processor.js";
import type { PostProcessor } from "./post-processor.js";

export type PostProcessorStrategy = "auto" | "fake" | "real";

export function createPostProcessor(strategy: PostProcessorStrategy): PostProcessor {
  const apiKey = process.env.DEERAPI_KEY;
  const baseUrl = process.env.DEERAPI_BASE_URL;

  if (strategy === "fake") {
    return new FakePostProcessor();
  }

  if (strategy === "real") {
    if (!apiKey || !baseUrl) {
      throw new Error("DEERAPI_KEY or DEERAPI_BASE_URL is missing.");
    }

    return new DeerApiPostProcessor({
      apiKey,
      baseUrl,
    });
  }

  if (apiKey && baseUrl) {
    return new DeerApiPostProcessor({
      apiKey,
      baseUrl,
    });
  }

  return new FakePostProcessor();
}

