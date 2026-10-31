export type Expense = {
  id: string;
  /** 立て替えた人 */
  payer: string;
  /** 金額（円・整数） */
  amount: number;
  /** 割り勘の対象の人たち（並び順が端数の割り振り順） */
  participants: string[];
  memo: string;
};

export type Transfer = {
  from: string;
  to: string;
  amount: number;
};

/** 人ごとの収支（立て替えた額 − 負担額）。プラスは受け取る側、マイナスは払う側。 */
export function balances(expenses: Expense[]): Map<string, number> {
  const result = new Map<string, number>();
  const add = (name: string, value: number) =>
    result.set(name, (result.get(name) ?? 0) + value);

  for (const expense of expenses) {
    const members = Array.from(new Set(expense.participants));
    if (
      members.length === 0 ||
      !Number.isInteger(expense.amount) ||
      expense.amount <= 0
    ) {
      continue;
    }
    const share = Math.floor(expense.amount / members.length);
    const rest = expense.amount - share * members.length;
    add(expense.payer, expense.amount);
    members.forEach((name, index) => {
      // 端数は、対象の並び順で先頭の人から1円ずつ負担する
      add(name, -(share + (index < rest ? 1 : 0)));
    });
  }
  return result;
}

/** 誰が誰にいくら払うかの一覧。送金回数が少なくなるよう、大きい額どうしを突き合わせる。 */
export function settle(expenses: Expense[]): Transfer[] {
  const entries = Array.from(balances(expenses).entries()).filter(
    ([, v]) => v !== 0,
  );
  const byAmount = (a: [string, number], b: [string, number]) =>
    Math.abs(b[1]) - Math.abs(a[1]) || a[0].localeCompare(b[0], "ja");
  const payers = entries.filter(([, v]) => v < 0).sort(byAmount);
  const receivers = entries.filter(([, v]) => v > 0).sort(byAmount);

  const transfers: Transfer[] = [];
  let i = 0;
  let j = 0;
  while (i < payers.length && j < receivers.length) {
    const pay = Math.min(-payers[i][1], receivers[j][1]);
    transfers.push({ from: payers[i][0], to: receivers[j][0], amount: pay });
    payers[i][1] += pay;
    receivers[j][1] -= pay;
    if (payers[i][1] === 0) i++;
    if (receivers[j][1] === 0) j++;
  }
  return transfers;
}
