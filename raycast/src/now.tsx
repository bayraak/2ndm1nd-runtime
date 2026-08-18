import { Detail, ActionPanel, Action } from "@raycast/api";
import { useEffect, useState } from "react";
import { getNow } from "./api";

export default function Now() {
  const [markdown, setMarkdown] = useState("Loading the Now recommendation…");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    getNow()
      .then((now) => setMarkdown(now.replace(/^---[\s\S]*?---\n/, ""))) // strip frontmatter
      .catch((e) => setMarkdown(`# Error\n\n${e.message}`))
      .finally(() => setLoading(false));
  }, []);

  return (
    <Detail
      isLoading={loading}
      markdown={markdown}
      actions={
        <ActionPanel>
          <Action.CopyToClipboard title="Copy Recommendation" content={markdown} />
        </ActionPanel>
      }
    />
  );
}
