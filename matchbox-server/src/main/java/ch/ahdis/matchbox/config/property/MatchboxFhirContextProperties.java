package ch.ahdis.matchbox.config.property;

import org.checkerframework.checker.nullness.qual.Nullable;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The properties in 'matchbox.fhir.context'.
 *
 * @author Quentin Ligier
 **/
@Component
@ConfigurationProperties(prefix = "matchbox.fhir.context")
public class MatchboxFhirContextProperties {

	private @Nullable Map<String, Set<String>> suppressWarnInfo, suppressError;

	private @Nullable List<String> igsPreloaded;

	private boolean onlyOneEngine = false;

	private boolean httpReadOnly = false;

	private boolean ssrfProtectionEnabled = true;

	/**
	 * Register conformance resources from packages lazily, parsing each one on first use instead of parsing every
	 * resource of every package while the engine is built.
	 *
	 * Off by default: it changes when parsing happens, so the first requests after startup are slower while the
	 * resources they need are materialised.
	 */
	private boolean lazyLoadPackageResources = false;

	private MatchboxFhirContextLlmProperties llm = new MatchboxFhirContextLlmProperties();

	public @Nullable Map<String, Set<String>> getSuppressWarnInfo() {
		return this.suppressWarnInfo;
	}

	public void setSuppressWarnInfo(final @Nullable Map<String, Set<String>> suppressWarnInfo) {
		this.suppressWarnInfo = suppressWarnInfo;
	}

	public @Nullable Map<String, Set<String>> getSuppressError() {
		return this.suppressError;
	}

	public void setSuppressError(final @Nullable Map<String, Set<String>> suppressError) {
		this.suppressError = suppressError;
	}

	public @Nullable List<String> getIgsPreloaded() {
		return this.igsPreloaded;
	}

	public void setIgsPreloaded(final @Nullable List<String> igsPreloaded) {
		this.igsPreloaded = igsPreloaded;
	}

	public void setOnlyOneEngine(final boolean onlyOneEngine) {
		this.onlyOneEngine = onlyOneEngine;
	}

	public boolean isOnlyOneEngine() {
		return this.onlyOneEngine;
	}

	public void setLazyLoadPackageResources(final boolean lazyLoadPackageResources) {
		this.lazyLoadPackageResources = lazyLoadPackageResources;
	}

	public boolean isLazyLoadPackageResources() {
		return this.lazyLoadPackageResources;
	}

	public void setHttpReadOnly(final boolean httpReadOnly) {
		this.httpReadOnly = httpReadOnly;
	}

	public boolean isHttpReadOnly() {
		return this.httpReadOnly;
	}

	public boolean isSsrfProtectionEnabled() {
		return this.ssrfProtectionEnabled;
	}

	public void setSsrfProtectionEnabled(final boolean ssrfProtectionEnabled) {
		this.ssrfProtectionEnabled = ssrfProtectionEnabled;
	}

	public MatchboxFhirContextLlmProperties getLlm() {
		return this.llm;
	}

	public void setLlm(final MatchboxFhirContextLlmProperties llm) {
		this.llm = llm;
	}
}
