PR の説明（本文）を直すときは、新しい本文を Write で .pr-body.md に書いてから gh pr edit 番号 --body-file .pr-body.md を1つだけ動かす（$(...)・&&・| でつながない。つなぐと許可されない）。.pr-body.md はコミットしない。Issue は gh issue view 番号 で読める。
