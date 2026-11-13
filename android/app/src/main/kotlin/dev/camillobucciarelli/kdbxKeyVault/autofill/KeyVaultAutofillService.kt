package dev.camillobucciarelli.kdbxKeyVault.autofill

import android.app.PendingIntent
import android.content.pm.ApplicationInfo
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.util.Log
import android.service.autofill.Dataset
import android.service.autofill.InlinePresentation
import android.service.autofill.AutofillService
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.inline.InlinePresentationSpec
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.v1.InlineSuggestionUi
import dev.camillobucciarelli.kdbxKeyVault.MainActivity
import dev.camillobucciarelli.kdbxKeyVault.R

/** Launch action and extra carrying a save capture into the app. */
internal const val ACTION_SAVE_CAPTURE = "dev.camillobucciarelli.kdbxKeyVault.SAVE_CAPTURE"
internal const val EXTRA_CAPTURE_TOKEN = "keyvault_autofill_capture_token"

/**
 * Structural tracing for the fill path. Counts, ids and hosts only — never a
 * field value (FR-015).
 *
 * Debug builds only, and not merely for noise: these lines name the hosts the
 * user is visiting, which has no business in a release device's logcat.
 */
private const val LOG_TAG = "CustodeAutofill"

private fun AutofillService.isDebugBuild(): Boolean {
    return (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
}

private inline fun AutofillService.trace(message: () -> String) {
    if (isDebugBuild()) {
        Log.d(LOG_TAG, message())
    }
}

/**
 * The row the system draws for one of our datasets. Shared with the picker so
 * the suggestion and the list it opens look like the same product.
 *
 * Never given a password: a presentation is rendered in the filled app's
 * process (FR-015).
 */
internal fun datasetPresentation(
    packageName: String,
    title: String,
    subtitle: String,
): RemoteViews {
    return RemoteViews(packageName, R.layout.autofill_dataset_item).apply {
        setTextViewText(R.id.autofill_dataset_title, title)
        setTextViewText(R.id.autofill_dataset_subtitle, subtitle)
        setViewVisibility(
            R.id.autofill_dataset_subtitle,
            if (subtitle.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE,
        )
    }
}

/**
 * Native Android Autofill v2 service.
 *
 * It reads only the app-published Android encrypted cache. It never opens or
 * writes KDBX files. The fill response exposes only an authenticated picker;
 * secrets are decrypted after explicit user selection.
 */
class KeyVaultAutofillService : AutofillService() {
    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback,
    ) {
        if (cancellationSignal.isCanceled) {
            return
        }

        val parsed = request.fillContexts.lastOrNull()?.structure?.let { structure ->
            AssistStructureCredentialParser.parse(structure)
        }
        if (parsed == null || !parsed.hasCredentialFields) {
            trace {
                "no fill: parsed=${parsed != null} " +
                    "usernameFields=${parsed?.usernameFields?.size ?: 0} " +
                    "passwordFields=${parsed?.passwordFields?.size ?: 0} " +
                    "package=${parsed?.packageName} webDomains=${parsed?.webDomains}"
            }
            callback.onSuccess(null)
            return
        }

        val store = AndroidAutofillStore(applicationContext)
        val metadata = store.readCredentialMetadata()
        if (metadata.isEmpty()) {
            trace { "no fill: the published cache holds no entries" }
            callback.onSuccess(null)
            return
        }
        val targets = AndroidAutofillNormalizer.normalizedRequestTargets(
            packageName = parsed.packageName,
            webDomains = parsed.webDomains,
        )
        if (targets.isEmpty()) {
            trace {
                "no fill: no usable target from package=${parsed.packageName} " +
                    "webDomains=${parsed.webDomains}"
            }
            callback.onSuccess(null)
            return
        }
        trace {
            "fill: entries=${metadata.size} targets=$targets " +
                "strongMatches=${AndroidAutofillCredentialMatcher.strongMatches(metadata, targets).size} " +
                "usernameFields=${parsed.usernameFields.size} passwordFields=${parsed.passwordFields.size} " +
                "inlineRequested=${request.inlineSuggestionsRequestOrNull() != null} " +
                inlineTrace(request)
        }

        val usernameIds = parsed.usernameFields.map { it.autofillId }
        val passwordIds = parsed.passwordFields.map { it.autofillId }
        val allIds = parsed.fields.map { it.autofillId }
        val pickerPendingIntent = pickerPendingIntent(request.id, parsed)
        val pickerTitle = if (parsed.webDomains.isNotEmpty()) {
            getString(R.string.autofill_dataset_select_for_site)
        } else {
            getString(R.string.autofill_dataset_select_for_app)
        }

        val response = FillResponse.Builder()
            .apply {
                val inlineDatasets = inlineDatasets(
                    request = request,
                    metadata = metadata,
                    targets = targets,
                    usernameIds = usernameIds,
                    passwordIds = passwordIds,
                    allIds = allIds,
                    pickerPendingIntent = pickerPendingIntent,
                    pickerTitle = pickerTitle,
                )
                for (dataset in inlineDatasets) {
                    addDataset(dataset)
                }
                // The picker dataset stays whatever happens: it is the whole
                // response on API 29 and on IMEs with no inline support (FR-004),
                // and the way into search when there are inline rows too.
                addDataset(
                    Dataset.Builder(presentation(pickerTitle))
                        .setAuthentication(pickerPendingIntent.intentSender)
                        .apply {
                            for (id in allIds) {
                                setValue(id, null as AutofillValue?)
                            }
                        }
                        .build(),
                )
                saveInfo(parsed)?.let(::setSaveInfo)
            }
            .build()

        if (!cancellationSignal.isCanceled) {
            callback.onSuccess(response)
        }
    }

    /** What the IME advertised, for the T001 evidence. */
    private fun inlineTrace(request: FillRequest): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return "inline=unsupportedApi"
        }
        val inline = request.inlineSuggestionsRequest ?: return "inline=none"
        val specs = inline.inlinePresentationSpecs
        return "maxSuggestionCount=${inline.maxSuggestionCount} " +
            "specs=${specs.size} " +
            "styleV1=${specs.firstOrNull()?.let { UiVersions.getVersions(it.style) }} " +
            "minSize=${specs.firstOrNull()?.minSize} maxSize=${specs.firstOrNull()?.maxSize}"
    }

    private fun pickerPendingIntent(
        requestId: Int,
        parsed: ParsedAutofillStructure,
    ): PendingIntent {
        val intent = AutofillPickerActivity.createIntent(
            context = this,
            usernameIds = parsed.usernameFields.map { it.autofillId },
            passwordIds = parsed.passwordFields.map { it.autofillId },
            packageName = parsed.packageName,
            webDomains = parsed.webDomains.toList(),
        )
        return PendingIntent.getActivity(
            this,
            requestId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * spec-016 T403/T404: one authenticated dataset per ranked match, each
     * carrying an inline presentation the IME draws on its suggestion strip.
     *
     * Empty when the IME asked for no inline suggestions, when it advertises a
     * style we cannot render, or below API 30 — in every one of those cases the
     * response falls back to the single picker dataset, unchanged.
     *
     * Each row shows title and username only. A password never reaches a
     * presentation: the secret is read inside [AutofillAuthActivity], after
     * authentication, in our own process (FR-005, FR-015).
     */
    private fun inlineDatasets(
        request: FillRequest,
        metadata: List<AndroidAutofillCredentialMetadata>,
        targets: List<AndroidAutofillServiceIdentifier>,
        usernameIds: List<AutofillId>,
        passwordIds: List<AutofillId>,
        allIds: List<AutofillId>,
        pickerPendingIntent: PendingIntent,
        pickerTitle: String,
    ): List<Dataset> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return emptyList()
        }
        val inlineRequest = request.inlineSuggestionsRequest ?: return emptyList()
        val specs = inlineRequest.inlinePresentationSpecs
        if (specs.isEmpty()) {
            return emptyList()
        }
        // The IME's own cap, and never more slots than it gave us specs for.
        val slots = minOf(inlineRequest.maxSuggestionCount, specs.size)
        if (slots <= 0) {
            return emptyList()
        }

        val matches = AndroidAutofillCredentialMatcher.topMatches(
            entries = metadata,
            targets = targets,
            limit = slots,
        )
        if (matches.isEmpty()) {
            return emptyList()
        }
        // T404: when more entries match than fit, the last slot opens the picker
        // rather than silently dropping the rest (FR-006).
        val hasOverflow = matches.size > slots - 1 &&
            AndroidAutofillCredentialMatcher.topMatches(metadata, targets, slots + 1).size > slots
        val credentialSlots = if (hasOverflow) slots - 1 else slots

        val datasets = mutableListOf<Dataset>()
        for ((index, entry) in matches.take(credentialSlots).withIndex()) {
            val spec = specs.getOrNull(index) ?: break
            val presentation = inlinePresentation(
                spec = spec,
                title = entry.title.ifBlank { entry.displayService },
                subtitle = entry.username,
                attribution = pickerPendingIntent,
            ) ?: return emptyList()

            val authIntent = PendingIntent.getActivity(
                this,
                (request.id.toString() + entry.id).hashCode(),
                AutofillAuthActivity.createIntent(
                    context = this,
                    entryId = entry.id,
                    usernameIds = usernameIds,
                    passwordIds = passwordIds,
                ),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            datasets.add(
                Dataset.Builder(presentation(entry.title.ifBlank { entry.displayService }))
                    .setInlinePresentation(presentation)
                    .setAuthentication(authIntent.intentSender)
                    .apply {
                        for (id in allIds) {
                            setValue(id, null as AutofillValue?)
                        }
                    }
                    .build(),
            )
        }

        if (hasOverflow && datasets.isNotEmpty()) {
            val spec = specs.getOrNull(datasets.size) ?: specs.last()
            inlinePresentation(
                spec = spec,
                title = getString(R.string.autofill_inline_search_custode),
                subtitle = "",
                attribution = pickerPendingIntent,
            )?.let { overflow ->
                datasets.add(
                    Dataset.Builder(presentation(pickerTitle))
                        .setInlinePresentation(overflow)
                        .setAuthentication(pickerPendingIntent.intentSender)
                        .apply {
                            for (id in allIds) {
                                setValue(id, null as AutofillValue?)
                            }
                        }
                        .build(),
                )
            }
        }
        return datasets
    }

    /** Null when the IME advertises a UI version we cannot build a Slice for. */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun inlinePresentation(
        spec: InlinePresentationSpec,
        title: String,
        subtitle: String,
        attribution: PendingIntent,
    ): InlinePresentation? {
        if (!UiVersions.getVersions(spec.style).contains(UiVersions.INLINE_UI_VERSION_1)) {
            return null
        }
        val content = InlineSuggestionUi.newContentBuilder(attribution)
            .setTitle(title)
            .apply { if (subtitle.isNotEmpty()) setSubtitle(subtitle) }
            .setContentDescription(
                if (subtitle.isEmpty()) title else getString(
                    R.string.autofill_picker_row_content_description,
                    title,
                    subtitle,
                ),
            )
            .build()
        return InlinePresentation(content.slice, spec, false)
    }

    /**
     * Declares what the response is able to save. A screen with no password
     * field has nothing worth capturing, so it gets no save bar at all.
     */
    private fun saveInfo(parsed: ParsedAutofillStructure): SaveInfo? {
        val passwordIds = parsed.passwordFields.map { it.autofillId }
        if (passwordIds.isEmpty()) {
            return null
        }
        val usernameIds = parsed.usernameFields.map { it.autofillId }
        val type = if (usernameIds.isEmpty()) {
            SaveInfo.SAVE_DATA_TYPE_PASSWORD
        } else {
            SaveInfo.SAVE_DATA_TYPE_PASSWORD or SaveInfo.SAVE_DATA_TYPE_USERNAME
        }
        return SaveInfo.Builder(type, passwordIds.toTypedArray())
            .apply {
                if (usernameIds.isNotEmpty()) {
                    setOptionalIds(usernameIds.toTypedArray())
                }
            }
            .build()
    }

    /**
     * Captures the submitted credential and hands the app a token for it. The
     * password stays in this process's memory: it never reaches an `Intent`
     * extra, which would pass through the system server (research R4, D5).
     */
    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        val parsed = request.fillContexts.lastOrNull()?.structure?.let { structure ->
            AssistStructureCredentialParser.parse(structure)
        }
        val submitted = parsed?.let { SubmittedCredentialExtractor.extract(it.submittedFields) }
        if (parsed == null || submitted == null) {
            trace {
                "no save: parsed=${parsed != null} submitted=${submitted != null} " +
                    "submittedFields=${parsed?.submittedFields?.size ?: 0}"
            }
            callback.onSuccess()
            return
        }

        val webDomain = parsed.webDomains.firstOrNull()
        val association = webDomain ?: parsed.packageName
        val store = AndroidAutofillStore(applicationContext)
        if (store.isDeclinedSave(association, submitted.username)) {
            // The user already said no to this submission (FR-011).
            trace { "no save: previously declined for association=$association" }
            callback.onSuccess()
            return
        }

        val capture = AndroidAutofillCaptureHolder.shared.store(
            username = submitted.username,
            password = submitted.password,
            packageName = parsed.packageName,
            webDomain = webDomain,
        )
        val intent = Intent(this, MainActivity::class.java)
            .setAction(ACTION_SAVE_CAPTURE)
            .putExtra(EXTRA_CAPTURE_TOKEN, capture.token)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pendingIntent = PendingIntent.getActivity(
            this,
            capture.token.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // The token is never logged: it is the capability that reads the captured
        // password back. Its presence is all a trace needs.
        trace {
            "save: captured association=$association " +
                "usernameCaptured=${submitted.username.isNotEmpty()} " +
                "usernameFields=${parsed.usernameFields.size} " +
                "submittedFields=${parsed.submittedFields.size} " +
                "pending=${AndroidAutofillCaptureHolder.shared.size()}"
        }
        callback.onSuccess(pendingIntent.intentSender)
    }

    /**
     * The inline request only exists from API 30. Reading it through one helper
     * keeps the version check out of the fill path.
     */
    private fun FillRequest.inlineSuggestionsRequestOrNull(): Any? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            inlineSuggestionsRequest
        } else {
            null
        }
    }

    private fun presentation(text: String): RemoteViews {
        return datasetPresentation(
            packageName = packageName,
            title = text,
            subtitle = getString(R.string.autofill_dataset_subtitle_open_custode),
        )
    }
}
