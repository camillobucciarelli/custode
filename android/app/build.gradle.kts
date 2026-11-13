import java.util.Properties

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.github.triplet.play")
}

android {
    namespace = "dev.camillobucciarelli.kdbxKeyVault"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.camillobucciarelli.kdbxKeyVault"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("upload") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("upload")
        }

        release {
            signingConfig = signingConfigs.getByName("upload")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// Unit tests run on the debug variant only. `GeneratedPluginRegistrant.java` is
// generated once for all variants and registers dev-dependency plugins such as
// `integration_test`, which the Flutter Gradle plugin deliberately keeps out of
// release. Compiling release unit tests therefore fails on a symbol that is
// absent by design, and release unit tests buy nothing here.
androidComponents {
    beforeVariants(selector().withBuildType("release")) { variant ->
        variant.hostTests[com.android.build.api.variant.HostTestBuilder.UNIT_TEST_TYPE]?.enable = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.biometric:biometric:1.1.0")
    // spec-016 T102: InlineSuggestionUi, the only supported way to build the
    // Slice an IME renders on its suggestion strip.
    implementation("androidx.autofill:autofill:1.3.0")
    // spec 023 T403: the Credential Manager *provider* APIs
    // (CredentialProviderService, BeginGetCredentialRequest,
    // PublicKeyCredentialEntry, PendingIntentHandler). Only the base artifact
    // is needed — `credentials-play-services-auth` is for the client side,
    // which this app is not.
    //
    // Every provider entry point is gated on API 34: `minSdk` here is 29, and
    // below 34 the platform has no credential provider to register with
    // (FR-013).
    implementation("androidx.credentials:credentials:1.6.0")
    testImplementation("junit:junit:4.13.2")
    // The JVM unit tests run against the SDK's stub android.jar, where
    // org.json throws "not mocked". The real library stands in for it so the
    // request parsing of spec 023 T805 is testable off-device.
    testImplementation("org.json:json:20240303")
}

play {
    val serviceAccountEnv = System.getenv("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON")
    serviceAccountCredentials.set(
        if (serviceAccountEnv != null) file(serviceAccountEnv)
        else rootProject.file("play-service-account.json")
    )
    track.set("production")
    artifactDir.set(
        rootProject.layout.buildDirectory.dir("app/outputs/bundle/release").get().asFile
    )
}
