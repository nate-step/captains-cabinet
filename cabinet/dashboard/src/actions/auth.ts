'use server'

import { createSession, destroySession, checkPassword } from '@/lib/auth'
import { redirect } from 'next/navigation'

export async function login(
  _prevState: { error: string } | null,
  formData: FormData
) {
  const password = formData.get('password') as string
  if (!checkPassword(password)) {
    return { error: 'Invalid password' }
  }
  await createSession()
  redirect('/')
}

export async function logout() {
  await destroySession()
  redirect('/login')
}
