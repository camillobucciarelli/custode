package dev.camillobucciarelli.kdbxKeyVault.autofill

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidAutofillCredentialMatcherTest {
    @Test
    fun strongMatchRequiresExactNormalizedHost() {
        val entry = credential(
            id = "entry-1",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
            ),
        )

        assertTrue(
            AndroidAutofillCredentialMatcher.isStrongMatch(
                entry,
                listOf(AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "www.example.com")),
            ),
        )
        assertFalse(
            AndroidAutofillCredentialMatcher.isStrongMatch(
                entry,
                listOf(AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "evil-example.com")),
            ),
        )
    }

    @Test
    fun phishingSubdomainDoesNotStrongMatchParentDomain() {
        val entry = credential(
            id = "entry-1",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
            ),
        )
        val phishingTarget = listOf(
            AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com.evil.com"),
        )

        assertFalse(AndroidAutofillCredentialMatcher.isStrongMatch(entry, phishingTarget))
        assertEquals(emptyList<AndroidAutofillCredentialMetadata>(), AndroidAutofillCredentialMatcher.strongMatches(listOf(entry), phishingTarget))
    }

    @Test
    fun strongMatchRequiresExactAndroidPackage() {
        val entry = credential(
            id = "entry-1",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(
                    AndroidAutofillServiceIdentifierType.AndroidPackage,
                    "com.example.app",
                ),
            ),
        )

        assertTrue(
            AndroidAutofillCredentialMatcher.isStrongMatch(
                entry,
                listOf(
                    AndroidAutofillServiceIdentifier(
                        AndroidAutofillServiceIdentifierType.AndroidPackage,
                        "com.example.app",
                    ),
                ),
            ),
        )
        assertFalse(
            AndroidAutofillCredentialMatcher.isStrongMatch(
                entry,
                listOf(
                    AndroidAutofillServiceIdentifier(
                        AndroidAutofillServiceIdentifierType.AndroidPackage,
                        "com.example.app.beta",
                    ),
                ),
            ),
        )
    }

    @Test
    fun partialTargetTokenIsPossibleMatchOnly() {
        val entry = credential(
            id = "entry-1",
            title = "Example Bank",
            displayService = "examplebank.com",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "examplebank.com"),
            ),
        )
        val target = listOf(
            AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "bank-login.test"),
        )

        assertFalse(AndroidAutofillCredentialMatcher.isStrongMatch(entry, target))
        assertEquals(listOf(entry), AndroidAutofillCredentialMatcher.possibleMatches(listOf(entry), target))
    }

    // spec-016 FR-013 (T602): a saved site entry must not be handed to whatever
    // page the browser happens to be showing when the domain could not be read.
    @Test
    fun browserPackageAloneIsNeverAStrongMatch() {
        val siteEntry = credential(
            id = "entry-1",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
            ),
        )
        val browserTarget = listOf(
            AndroidAutofillServiceIdentifier(
                AndroidAutofillServiceIdentifierType.AndroidPackage,
                "com.android.chrome",
            ),
        )

        assertFalse(AndroidAutofillCredentialMatcher.isStrongMatch(siteEntry, browserTarget))
        assertEquals(
            emptyList<AndroidAutofillCredentialMetadata>(),
            AndroidAutofillCredentialMatcher.strongMatches(listOf(siteEntry), browserTarget),
        )
    }

    // The site entry, not the browser, is what a browser request matches.
    @Test
    fun browserRequestStrongMatchesThePageDomain() {
        val siteEntry = credential(
            id = "entry-1",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
            ),
        )
        val targets = AndroidAutofillNormalizer.normalizedRequestTargets(
            packageName = "com.android.chrome",
            webDomains = listOf("https://www.example.com/login"),
        )

        assertEquals(
            listOf(siteEntry),
            AndroidAutofillCredentialMatcher.strongMatches(listOf(siteEntry), targets),
        )
    }

    // spec-016 T401: the inline strip and the picker must agree about what
    // matches, so ranking only orders and truncates the existing rules.
    @Test
    fun topMatchesPutsStrongMatchesFirstAndIsDeterministic() {
        val strongA = credential(
            id = "strong-a",
            title = "Alpha",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
            ),
        )
        val strongB = credential(
            id = "strong-b",
            title = "Beta",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
            ),
        )
        val possible = credential(
            id = "possible",
            title = "Example partner",
            displayService = "partner.example.org",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "partner.example.org"),
            ),
        )
        val unrelated = credential(
            id = "unrelated",
            title = "Something else",
            displayService = "other.test",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "other.test"),
            ),
        )
        val entries = listOf(unrelated, possible, strongB, strongA)
        val targets = listOf(
            AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
        )

        val top = AndroidAutofillCredentialMatcher.topMatches(entries, targets, limit = 3)

        assertEquals(listOf("strong-a", "strong-b"), top.take(2).map { it.id })
        assertFalse(top.contains(unrelated))
        // Same input, same output — an IME strip that reshuffles between requests
        // is worse than no strip.
        assertEquals(
            top,
            AndroidAutofillCredentialMatcher.topMatches(entries.reversed(), targets, limit = 3),
        )
    }

    @Test
    fun topMatchesNeverExceedsTheSlotCountAndZeroSlotsYieldNothing() {
        val entries = (1..5).map { index ->
            credential(
                id = "entry-$index",
                title = "Entry $index",
                identifiers = listOf(
                    AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
                ),
            )
        }
        val targets = listOf(
            AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
        )

        assertEquals(2, AndroidAutofillCredentialMatcher.topMatches(entries, targets, limit = 2).size)
        assertEquals(0, AndroidAutofillCredentialMatcher.topMatches(entries, targets, limit = 0).size)
    }

    // FR-005/FR-015: what an inline row is built from carries no secret at all —
    // the metadata type has no password to leak.
    @Test
    fun rankedMatchesCarryNoSecretMaterial() {
        val entry = credential(
            id = "entry-1",
            identifiers = listOf(
                AndroidAutofillServiceIdentifier(AndroidAutofillServiceIdentifierType.Domain, "example.com"),
            ),
        )
        val fields = AndroidAutofillCredentialMetadata::class.java.declaredFields.map { it.name }

        // `hasPassword` is a boolean flag, not a secret.
        assertEquals(listOf("hasPassword"), fields.filter { it.contains("password", ignoreCase = true) })
        assertFalse(Regex("(?i)(?<!has)password=").containsMatchIn(entry.toString()))
    }

    private fun credential(
        id: String,
        title: String = "Example",
        username: String = "alice",
        displayService: String = "example.com",
        identifiers: List<AndroidAutofillServiceIdentifier>,
    ): AndroidAutofillCredentialMetadata {
        return AndroidAutofillCredentialMetadata(
            id = id,
            title = title,
            username = username,
            displayService = displayService,
            serviceIdentifiers = identifiers,
            updatedAtEpochMs = 1,
        )
    }
}
