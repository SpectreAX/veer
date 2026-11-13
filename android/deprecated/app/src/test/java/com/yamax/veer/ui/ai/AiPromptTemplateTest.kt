package com.yamax.veer.ui.ai

import com.yamax.veer.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AiPromptTemplateTest {
    @Test
    fun `quick templates have stable unique ids and reviewable prompts`() {
        assertEquals(AI_PROMPT_TEMPLATES.size, AI_PROMPT_TEMPLATES.map { it.id }.distinct().size)
        assertTrue(AI_PROMPT_TEMPLATES.all { it.id.isNotBlank() })
        assertTrue(AI_PROMPT_TEMPLATES.all { it.titleRes != 0 })
        assertTrue(AI_PROMPT_TEMPLATES.all { it.promptRes != 0 })
        assertTrue(
            AI_PROMPT_TEMPLATES.any {
                it.promptRes == R.string.ai_template_chatgpt_us_prompt
            },
        )
        assertTrue(
            AI_PROMPT_TEMPLATES.any {
                it.promptRes == R.string.ai_template_low_latency_prompt
            },
        )
    }
}
