package com.yamax.veer.core_profile

import com.yamax.veer.core_profile.internal.parser.PipelineStage
import com.yamax.veer.core_profile.internal.parser.ValidationError

internal sealed class ImportState {
    object Idle : ImportState()
    data class Running(val stage: PipelineStage, val message: String) : ImportState()
    data class Success(val profileName: String) : ImportState()
    data class Failure(val errors: List<ValidationError>, val message: String) : ImportState()
}
