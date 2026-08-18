import { List, ActionPanel, Action, Icon } from "@raycast/api";
import { useState } from "react";
import { search, fmtTime, SearchHit } from "./api";

export default function Search() {
  const [results, setResults] = useState<SearchHit[]>([]);
  const [loading, setLoading] = useState(false);

  async function onSearch(text: string) {
    if (text.trim().length < 2) {
      setResults([]);
      return;
    }
    setLoading(true);
    try {
      setResults(await search(text));
    } catch {
      setResults([]);
    } finally {
      setLoading(false);
    }
  }

  return (
    <List
      isLoading={loading}
      onSearchTextChange={onSearch}
      searchBarPlaceholder="Search your captured activity…"
      throttle
    >
      {results.map((r) => (
        <List.Item
          key={r.id}
          icon={Icon.MagnifyingGlass}
          title={r.snippet.replace(/«|»/g, "")}
          subtitle={`${r.source} · ${r.kind}`}
          accessories={[{ text: fmtTime(r.ts) }]}
          actions={
            <ActionPanel>
              <Action.CopyToClipboard content={r.snippet.replace(/«|»/g, "")} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
