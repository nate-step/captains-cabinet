'use server'

import { dockerExec } from '@/lib/docker'
import { revalidatePath } from 'next/cache'

const CONFIG_PATH = '/opt/founders-cabinet/instance/config/product.yml'

const PRODUCT_FIELDS = ['name', 'description', 'repo', 'repo_branch', 'captain_name', 'mount_path']
const VOICE_FIELDS = ['enabled', 'provider', 'model', 'mode', 'naturalize']
const IMAGE_GEN_FIELDS = ['enabled', 'provider', 'model']
const EMBEDDINGS_FIELDS = ['provider', 'dimensions']
const VOICE_OFFICER_FIELDS = ['stability', 'speeds', 'voices', 'models', 'naturalize_prompts']

export async function updateProductConfig(field: string, value: string) {
  try {
    if (!PRODUCT_FIELDS.includes(field)) {
      return { success: false, error: `Invalid field: ${field}` }
    }
    // field is like "name", "description", etc. under the product: section
    const safeValue = value.replace(/'/g, "'\\''")
    await dockerExec(
      `sed -i '/^product:/,/^[a-z]/{s/^  ${field}: .*/  ${field}: ${safeValue}/}' ${CONFIG_PATH}`
    )
    revalidatePath('/settings')
    revalidatePath('/')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update product config',
    }
  }
}

export async function updateGlobalVoiceConfig(field: string, value: string) {
  try {
    if (!VOICE_FIELDS.includes(field)) {
      return { success: false, error: `Invalid field: ${field}` }
    }
    const safeValue = value.replace(/'/g, "'\\''")
    await dockerExec(
      `sed -i '/^voice:/,/^[a-z]/{s/^  ${field}: .*/  ${field}: ${safeValue}/}' ${CONFIG_PATH}`
    )
    revalidatePath('/settings')
    revalidatePath('/')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update voice config',
    }
  }
}

export async function updateImageGenConfig(field: string, value: string) {
  try {
    if (!IMAGE_GEN_FIELDS.includes(field)) {
      return { success: false, error: `Invalid field: ${field}` }
    }
    const safeValue = value.replace(/'/g, "'\\''")
    await dockerExec(
      `sed -i '/^image_generation:/,/^[a-z]/{s/^  ${field}: .*/  ${field}: ${safeValue}/}' ${CONFIG_PATH}`
    )
    revalidatePath('/settings')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update image generation config',
    }
  }
}

export async function updateEmbeddingsConfig(field: string, value: string) {
  try {
    if (!EMBEDDINGS_FIELDS.includes(field) && field !== 'models.storage' && field !== 'models.query') {
      return { success: false, error: `Invalid field: ${field}` }
    }
    const safeValue = value.replace(/'/g, "'\\''")
    // Handle nested models section
    if (field === 'models.storage' || field === 'models.query') {
      const subField = field.split('.')[1]
      await dockerExec(
        `sed -i '/^embeddings:/,/^[a-z]/{/^  models:/,/^  [a-z]/{s/^    ${subField}: .*/    ${subField}: ${safeValue}/}}' ${CONFIG_PATH}`
      )
    } else {
      await dockerExec(
        `sed -i '/^embeddings:/,/^[a-z]/{s/^  ${field}: .*/  ${field}: ${safeValue}/}' ${CONFIG_PATH}`
      )
    }
    revalidatePath('/settings')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update embeddings config',
    }
  }
}

export async function updateOfficerVoiceConfig(role: string, field: string, value: string) {
  try {
    if (!VOICE_OFFICER_FIELDS.includes(field)) {
      return { success: false, error: `Invalid field: ${field}` }
    }
    const safeValue = value.replace(/'/g, "'\\''")
    // field is like "voices", "stability", "speeds", "naturalize_prompts", "models"
    // These are under voice.<field>.<role>
    await dockerExec(
      `sed -i '/^voice:/,/^[a-z]/{/^  ${field}:/,/^  [a-z]/{s/^    ${role}: .*/    ${role}: ${safeValue}/}}' ${CONFIG_PATH}`
    )
    revalidatePath(`/officers/${role}`)
    revalidatePath('/officers')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update officer voice config',
    }
  }
}

export async function updateNotionConfig(field: string, value: string) {
  try {
    const safeValue = value.replace(/'/g, "'\\''")
    await dockerExec(
      `sed -i '/^notion:/,/^[a-z]/{s/^  ${field}: .*/  ${field}: ${safeValue}/}' ${CONFIG_PATH}`
    )
    revalidatePath('/integrations')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update Notion config',
    }
  }
}

export async function updateLinearConfig(field: string, value: string) {
  try {
    const safeValue = value.replace(/'/g, "'\\''")
    await dockerExec(
      `sed -i '/^linear:/,/^[a-z]/{s/^  ${field}: .*/  ${field}: ${safeValue}/}' ${CONFIG_PATH}`
    )
    revalidatePath('/integrations')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update Linear config',
    }
  }
}
