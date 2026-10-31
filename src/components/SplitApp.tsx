"use client";

import { useMemo, useState, useSyncExternalStore } from "react";
import { settle } from "@/lib/settle";
import {
  STORAGE_KEY,
  formatYen,
  parseSplitData,
  type SplitData,
} from "@/lib/split-storage";

const listeners = new Set<() => void>();

function subscribe(callback: () => void): () => void {
  listeners.add(callback);
  window.addEventListener("storage", callback);
  return () => {
    listeners.delete(callback);
    window.removeEventListener("storage", callback);
  };
}

function getSnapshot(): string | null {
  return window.localStorage.getItem(STORAGE_KEY);
}

function getServerSnapshot(): string | null {
  return null;
}

function save(data: SplitData): void {
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
  listeners.forEach((l) => l());
}

export function SplitApp() {
  const raw = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  const data = useMemo(() => parseSplitData(raw), [raw]);
  const transfers = useMemo(() => settle(data.expenses), [data.expenses]);

  const [name, setName] = useState("");
  const [payer, setPayer] = useState("");
  const [amount, setAmount] = useState("");
  const [memo, setMemo] = useState("");
  // 空の配列は「全員」を表す（人が増えても既定は全員）
  const [targets, setTargets] = useState<string[]>([]);
  const [error, setError] = useState("");

  const currentPayer = data.people.includes(payer) ? payer : (data.people[0] ?? "");

  function addPerson(event: React.FormEvent) {
    event.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) return;
    if (data.people.includes(trimmed)) {
      setError("その名前はもう追加されています");
      return;
    }
    setError("");
    save({ ...data, people: [...data.people, trimmed] });
    setName("");
  }

  function addExpense(event: React.FormEvent) {
    event.preventDefault();
    const yen = Number(amount);
    if (!Number.isInteger(yen) || yen <= 0) {
      setError("金額は1円以上の整数で入力してください");
      return;
    }
    const participants = targets.length > 0 ? targets : data.people;
    setError("");
    save({
      ...data,
      expenses: [
        ...data.expenses,
        {
          id: crypto.randomUUID(),
          payer: currentPayer,
          amount: yen,
          participants: data.people.filter((p) => participants.includes(p)),
          memo: memo.trim(),
        },
      ],
    });
    setAmount("");
    setMemo("");
    setTargets([]);
  }

  function removeExpense(id: string) {
    save({ ...data, expenses: data.expenses.filter((x) => x.id !== id) });
  }

  function toggleTarget(person: string) {
    setTargets((prev) =>
      prev.includes(person) ? prev.filter((p) => p !== person) : [...prev, person],
    );
  }

  return (
    <main className="container">
      <h1>立て替え精算</h1>

      <section aria-labelledby="result-heading">
        <h2 id="result-heading">精算</h2>
        {data.expenses.length === 0 ? (
          <p className="muted">立て替えを記録すると、ここに誰が誰にいくら返すかが出ます。</p>
        ) : transfers.length === 0 ? (
          <p>貸し借りはありません。</p>
        ) : (
          <ul className="plain">
            {transfers.map((t) => (
              <li key={`${t.from}->${t.to}`}>
                {t.from}が{t.to}に{formatYen(t.amount)}返す
              </li>
            ))}
          </ul>
        )}
      </section>

      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}

      <section aria-labelledby="people-heading">
        <h2 id="people-heading">人</h2>
        <form onSubmit={addPerson} className="row">
          <label>
            名前
            <input value={name} onChange={(e) => setName(e.target.value)} />
          </label>
          <button type="submit">追加</button>
        </form>
        {data.people.length > 0 && <p>{data.people.join("、")}</p>}
      </section>

      <section aria-labelledby="expense-heading">
        <h2 id="expense-heading">立て替えを記録</h2>
        {data.people.length < 2 ? (
          <p className="muted">人を2人以上追加すると記録できます。</p>
        ) : (
          <form onSubmit={addExpense} className="stack">
            <label>
              立て替えた人
              <select value={currentPayer} onChange={(e) => setPayer(e.target.value)}>
                {data.people.map((p) => (
                  <option key={p} value={p}>
                    {p}
                  </option>
                ))}
              </select>
            </label>
            <label>
              金額（円）
              <input
                inputMode="numeric"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                required
              />
            </label>
            <fieldset>
              <legend>誰の分か（選ばないと全員）</legend>
              {data.people.map((p) => (
                <label key={p} className="check">
                  <input
                    type="checkbox"
                    checked={targets.includes(p)}
                    onChange={() => toggleTarget(p)}
                  />
                  {p}
                </label>
              ))}
            </fieldset>
            <label>
              メモ
              <input value={memo} onChange={(e) => setMemo(e.target.value)} />
            </label>
            <div>
              <button type="submit">記録する</button>
            </div>
          </form>
        )}
      </section>

      <section aria-labelledby="list-heading">
        <h2 id="list-heading">記録</h2>
        {data.expenses.length === 0 ? (
          <p className="muted">まだ記録がありません。</p>
        ) : (
          <ul className="plain">
            {data.expenses.map((x) => (
              <li key={x.id} className="record">
                <span>
                  {x.payer}が{formatYen(x.amount)}（{x.participants.join("、")}の分）
                  {x.memo && `　${x.memo}`}
                </span>
                <button type="button" onClick={() => removeExpense(x.id)}>
                  削除
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  );
}
