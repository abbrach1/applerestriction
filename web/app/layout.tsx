import "./globals.css";
import { AuthProvider } from "@/lib/auth";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "B-SAFE Admin",
  description: "Admin dashboard for B-SAFE parental controls",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <AuthProvider>{children}</AuthProvider>
      </body>
    </html>
  );
}
