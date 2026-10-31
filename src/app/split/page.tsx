import type { Metadata } from "next";
import { SplitApp } from "@/components/SplitApp";

export const metadata: Metadata = {
  title: "立て替え精算",
};

export default function SplitPage() {
  return <SplitApp />;
}
