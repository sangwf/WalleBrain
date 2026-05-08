export type ChatContentPart =
  | {
    type: "text";
    text: string;
  }
  | {
    type: "input_audio";
    input_audio: {
      data: string;
      format: "wav";
    };
  };

type ChatMessage = {
  role: "system" | "user" | "assistant";
  content: string | ChatContentPart[];
};

type LLMChatClientOptions = {
  baseUrl: string;
  apiKey: string;
};

type LLMChatResponse = {
  error?: {
    message?: string;
    type?: string;
  };
  choices?: Array<{
    message?: {
      content?: string;
    };
  }>;
  model?: string;
};

export class LLMChatClient {
  constructor(private readonly options: LLMChatClientOptions) {}

  async createChatCompletion(input: {
    model: string;
    messages: ChatMessage[];
    temperature?: number;
  }): Promise<{ content: string; model: string | null }> {
    const response = await fetch(this.options.baseUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.options.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: input.model,
        messages: input.messages,
        temperature: input.temperature ?? 0.2,
      }),
    });

    const data = await response.json() as LLMChatResponse;

    if (!response.ok || data.error) {
      throw new Error(data.error?.message ?? `LLM request failed with ${response.status}`);
    }

    const content = data.choices?.[0]?.message?.content;

    if (!content) {
      throw new Error("LLM response did not include assistant content.");
    }

    return {
      content,
      model: data.model ?? null,
    };
  }
}
