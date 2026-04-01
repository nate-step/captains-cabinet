import type { Metadata } from 'next'
import Nav from '@/components/nav'
import './globals.css'

export const metadata: Metadata = {
  title: "Founder's Cabinet",
  description: 'Admin dashboard for the Founder\'s Cabinet',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen bg-zinc-950 text-zinc-400 antialiased">
        <Nav />
        {/* Main content — offset for sidebar on desktop, top bar on mobile */}
        <main className="pt-14 md:pl-64 md:pt-0">
          <div className="mx-auto max-w-6xl px-4 py-8 sm:px-6 lg:px-8">
            {children}
          </div>
        </main>
      </body>
    </html>
  )
}
