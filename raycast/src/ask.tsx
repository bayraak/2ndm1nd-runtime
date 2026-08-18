import { Detail, Form, ActionPanel, Action, useNavigation, showToast, Toast } from "@raycast/api";
import { useState } from "react";
import { ask } from "./api";

function Answer({ question, answer }: { question: string; answer: string }) {
  const md = `## ${question}\n\n${answer}`;
  return (
    <Detail
      markdown={md}
      actions={
        <ActionPanel>
          <Action.CopyToClipboard title="Copy Answer" content={answer} />
        </ActionPanel>
      }
    />
  );
}

export default function Ask() {
  const { push } = useNavigation();
  const [loading, setLoading] = useState(false);

  async function onSubmit(values: { question: string }) {
    if (!values.question.trim()) return;
    setLoading(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "Asking the brain…" });
    try {
      const answer = await ask(values.question);
      toast.hide();
      push(<Answer question={values.question} answer={answer} />);
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "Failed";
      toast.message = (e as Error).message;
    } finally {
      setLoading(false);
    }
  }

  return (
    <Form
      isLoading={loading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Ask" onSubmit={onSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="question"
        title="Question"
        placeholder="What did I spend most of my time on this week?"
      />
      <Form.Description text="Runs an agentic query over your ledger + memory (may take up to a minute)." />
    </Form>
  );
}
