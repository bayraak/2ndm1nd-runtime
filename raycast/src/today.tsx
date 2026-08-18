import { List, ActionPanel, Action, Icon } from "@raycast/api";
import { useEffect, useState } from "react";
import { getSpans, fmtTime, Span } from "./api";

const ICONS: Record<string, Icon> = {
  coding: Icon.Code,
  browsing: Icon.Globe,
  chatting: Icon.SpeechBubble,
  "note-taking": Icon.Pencil,
};

export default function Today() {
  const [spans, setSpans] = useState<Span[]>([]);
  const [day, setDay] = useState("");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    getSpans()
      .then((r) => {
        setDay(r.day);
        setSpans(r.spans.slice().reverse()); // most recent first
      })
      .catch(() => setSpans([]))
      .finally(() => setLoading(false));
  }, []);

  return (
    <List isLoading={loading} navigationTitle={`Activity — ${day}`}>
      {spans.length === 0 && !loading && (
        <List.EmptyView title="No activity spans yet today" icon={Icon.Clock} />
      )}
      {spans.map((s, i) => {
        const ctx = [s.project, s.app].filter(Boolean).join(" · ");
        return (
          <List.Item
            key={i}
            icon={ICONS[s.activity] ?? Icon.Circle}
            title={`${fmtTime(s.t0)}–${fmtTime(s.t1)}  ${s.activity}`}
            subtitle={ctx}
            accessories={[{ text: `${s.minutes}m` }]}
            actions={
              <ActionPanel>
                <Action.CopyToClipboard content={`${fmtTime(s.t0)}–${fmtTime(s.t1)} ${s.activity} ${ctx}`} />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
