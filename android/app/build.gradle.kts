plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Distributed test APKs identify their exact build; local builds remain explicit.
val buildNumberInput = providers.environmentVariable("PINDO_BUILD_NUMBER").orNull
val commitInput = providers.environmentVariable("PINDO_COMMIT_SHA").orNull
require((buildNumberInput == null) == (commitInput == null)) {
    "PINDO_BUILD_NUMBER and PINDO_COMMIT_SHA must be provided together."
}
val distributionBuild = buildNumberInput?.let { value ->
    val number = value.toIntOrNull()
    require(value.matches(Regex("[1-9][0-9]*")) && number != null && number <= 2_099_999_000) {
        "PINDO_BUILD_NUMBER must be a positive integer no greater than 2099999000."
    }
    number
}
val sourceRevision = commitInput?.also { value ->
    require(value.matches(Regex("[0-9a-fA-F]{7,40}"))) {
        "PINDO_COMMIT_SHA must contain 7 to 40 hexadecimal characters."
    }
}?.lowercase()
val releaseStore = providers.environmentVariable("PINDO_ANDROID_KEYSTORE_PATH").orNull
val releasePassword = providers.environmentVariable("PINDO_ANDROID_KEYSTORE_PASSWORD").orNull
val releaseAlias = providers.environmentVariable("PINDO_ANDROID_KEY_ALIAS").orNull
require(listOf(releaseStore, releasePassword, releaseAlias).let { values -> values.all { it == null } || values.all { !it.isNullOrBlank() } }) {
    "Provide the complete Android release signing configuration."
}

android {
    namespace = "com.pindo.app"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.pindo.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1000 + (distributionBuild ?: 0)
        versionName = distributionBuild?.let { "0.6.0-build$it.${sourceRevision!!.take(7)}" } ?: "0.6.0-local"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        resValue("string", "app_name", "Pindo")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    signingConfigs {
        if (releaseStore != null) create("distribution") {
            storeType = "PKCS12"
            storeFile = file(releaseStore)
            storePassword = releasePassword
            keyAlias = releaseAlias
            keyPassword = releasePassword
        }
    }
    buildTypes {
        getByName("debug") {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Pindo Dev")
        }
        getByName("release") {
            isDebuggable = false
            if (releaseStore != null) signingConfig = signingConfigs.getByName("distribution")
        }
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.isIncludeAndroidResources = true
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("org.robolectric:robolectric:4.14.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
}

tasks.withType<Test>().configureEach {
    maxHeapSize = "1g"
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
    systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
    // Keep the managed environment's Java proxy/CA settings for Robolectric's
    // runtime SDK downloads; regular local and GitHub builds need no override.
    listOf("http.proxyHost", "http.proxyPort", "https.proxyHost", "https.proxyPort",
        "http.nonProxyHosts", "javax.net.ssl.trustStore").forEach { name ->
        System.getProperty(name)?.let { systemProperty(name, it) }
    }
}
