'use server'

import redis from '@/lib/redis'
import { revalidatePath } from 'next/cache'

export async function toggleKillSwitch() {
  try {
    const current = await redis.get('cabinet:killswitch')
    if (current === 'active') {
      await redis.del('cabinet:killswitch')
    } else {
      await redis.set('cabinet:killswitch', 'active')
    }
    revalidatePath('/')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error:
        err instanceof Error ? err.message : 'Failed to toggle kill switch',
    }
  }
}
