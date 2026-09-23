package ch.ahdis.matchbox.packages;

import java.io.ByteArrayInputStream;
/*
 * #%L
 * Matchbox Engine
 * %%
 * Copyright (C) 2022 ahdis
 * %%
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * #L%
 */
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.Optional;

import javax.annotation.Nonnull;

import ch.ahdis.matchbox.engine.exception.MatchboxUnsupportedFhirVersionException;
import ch.ahdis.matchbox.util.MatchboxServerUtils;
import org.hl7.fhir.convertors.factory.VersionConvertorFactory_30_50;
import org.hl7.fhir.convertors.factory.VersionConvertorFactory_40_50;
import org.hl7.fhir.convertors.factory.VersionConvertorFactory_43_50;
import org.hl7.fhir.r4.model.ConceptMap.ConceptMapGroupComponent;
import org.hl7.fhir.r5.context.CanonicalResourceManager.CanonicalResourceProxy;
import org.hl7.fhir.exceptions.FHIRException;
import org.hl7.fhir.r5.context.BaseWorkerContext.ResourceProxy;
import org.hl7.fhir.r5.context.SimpleWorkerContext;
import org.hl7.fhir.r5.model.CanonicalResource;
import org.hl7.fhir.r5.model.ImplementationGuide;
import org.hl7.fhir.r5.model.PackageInformation;
import org.hl7.fhir.r5.model.Resource;
import org.hl7.fhir.utilities.ByteProvider;
import org.hl7.fhir.utilities.FileUtilities;
import org.hl7.fhir.utilities.VersionUtilities;
import org.hl7.fhir.utilities.npm.FilesystemPackageCacheManager;
import org.hl7.fhir.utilities.npm.NpmPackage;
import org.hl7.fhir.validation.IgLoader;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import ca.uhn.fhir.context.FhirContext;
import ca.uhn.fhir.context.FhirVersionEnum;
import ca.uhn.fhir.i18n.Msg;
import ca.uhn.fhir.jpa.api.dao.DaoRegistry;
import ca.uhn.fhir.jpa.binary.api.IBinaryStorageSvc;
import ca.uhn.fhir.jpa.dao.data.INpmPackageVersionDao;
import ca.uhn.fhir.jpa.model.dao.JpaPid;
import ca.uhn.fhir.jpa.model.entity.NpmPackageVersionEntity;
import ca.uhn.fhir.jpa.model.entity.NpmPackageVersionResourceEntity;
import ca.uhn.fhir.jpa.packages.IHapiPackageCacheManager;
import ca.uhn.fhir.jpa.packages.JpaPackageCache;
import ca.uhn.fhir.jpa.packages.IHapiPackageCacheManager.PackageContents;
import ca.uhn.fhir.rest.server.exceptions.InternalErrorException;

import static ch.ahdis.matchbox.engine.MatchboxEngine.*;

/**
 * Loads packages from the classpath
 * 
 * @author oliveregger
 *
 */
public class IgLoaderFromJpaPackageCache extends IgLoader {

	protected static final org.slf4j.Logger log = org.slf4j.LoggerFactory.getLogger(IgLoaderFromJpaPackageCache.class);

	private IHapiPackageCacheManager myPackageCacheManager;
	private INpmPackageVersionDao myNpmPackageVersionDao;
	private DaoRegistry myDaoRegistry;
	private IBinaryStorageSvc myBinaryStorageSvc;
	private PlatformTransactionManager myTxManager;
	private final boolean lazyLoadPackageResources;

	private final Map<FhirVersionEnum, FhirContext> myVersionToContext = Collections.synchronizedMap(new HashMap<>());

	private FhirContext myCtx;

	public IgLoaderFromJpaPackageCache(FilesystemPackageCacheManager packageCacheManager, SimpleWorkerContext context,
			String theVersion, boolean debug, IHapiPackageCacheManager myPackageCacheManager,
			INpmPackageVersionDao myNpmPackageVersionDao, DaoRegistry myDaoRegistry, IBinaryStorageSvc myBinaryStorageSvc,
			PlatformTransactionManager myTxManager, boolean lazyLoadPackageResources) {
		super(packageCacheManager, context, theVersion, debug);
		this.lazyLoadPackageResources = lazyLoadPackageResources;
		this.myPackageCacheManager = myPackageCacheManager;
		this.myNpmPackageVersionDao = myNpmPackageVersionDao;
		this.myDaoRegistry = myDaoRegistry;
		this.myBinaryStorageSvc = myBinaryStorageSvc;
		this.myTxManager = myTxManager;
		this.myCtx = FhirContext.forCached(FhirVersionEnum.forVersionString(theVersion));
	}

	@Nonnull
	public FhirContext getFhirContext(FhirVersionEnum theFhirVersion) {
		return myVersionToContext.computeIfAbsent(theFhirVersion, FhirContext::forCached);
	}

	private void cleanModifierExtensions(org.hl7.fhir.r5.model.ConceptMap r) {
		for ( org.hl7.fhir.r5.model.ConceptMap.ConceptMapGroupComponent  group :r.getGroup()) {
			group.getElement().forEach(element -> {
				element.getTarget().forEach(target -> {
					target.getModifierExtension().clear();
				});
			});
		}
	}

	private void cleanModifierExtensions(org.hl7.fhir.r5.model.StructureMap r) {
		r.getContained().forEach(c -> {
			if (c instanceof org.hl7.fhir.r5.model.ConceptMap) {
				cleanModifierExtensions((org.hl7.fhir.r5.model.ConceptMap) c);
			}
		});
	}

	private void cleanModifierExtensions(org.hl7.fhir.r4.model.ConceptMap r) {
		for ( ConceptMapGroupComponent group :r.getGroup()) {
			group.getElement().forEach(element -> {
				element.getTarget().forEach(target -> {
					target.getModifierExtension().clear();
				});
			});
		}
	}

	private void cleanModifierExtensions(org.hl7.fhir.r4.model.StructureMap r) {
		r.getContained().forEach(c -> {
			if (c instanceof org.hl7.fhir.r4.model.ConceptMap) {
				cleanModifierExtensions((org.hl7.fhir.r4.model.ConceptMap) c);
			}
		});
	}

	private org.hl7.fhir.r5.model.Resource loadPackageEntity(NpmPackageVersionResourceEntity contents) {
		return loadPackageEntity(contents.getResourceBinary().getId(), contents.getFhirVersion(), contents.toString());
	}

	/**
	 * Loads and parses one package resource from its binary, without needing the JPA entity to still be attached.
	 * The lazy path keeps only primitives so that the persistence context can be cleared after indexing a package.
	 */
	private org.hl7.fhir.r5.model.Resource loadPackageEntity(final JpaPid binaryId,
																			  final FhirVersionEnum fhirVersion,
																			  final String describedBy) {
		try {
			final var binary = MatchboxServerUtils.getBinaryFromId(binaryId, myDaoRegistry);
			final byte[] resourceContentsBytes = MatchboxServerUtils.fetchBlobFromBinary(binary, myBinaryStorageSvc,
																												  myCtx);
			final String resourceContents = new String(resourceContentsBytes, StandardCharsets.UTF_8);
			switch (fhirVersion) {
			case DSTU3:
				return VersionConvertorFactory_30_50
						.convertResource(new org.hl7.fhir.dstu3.formats.JsonParser().parse(resourceContents));
			case R4:
				org.hl7.fhir.r4.model.Resource r = new org.hl7.fhir.r4.formats.JsonParser().parse(resourceContents);
				if (r instanceof org.hl7.fhir.r4.model.StructureMap ) {
					cleanModifierExtensions((org.hl7.fhir.r4.model.StructureMap) r);
				}
				return VersionConvertorFactory_40_50
						.convertResource(r);
			case R4B:
				return VersionConvertorFactory_43_50
						.convertResource(new org.hl7.fhir.r4b.formats.JsonParser().parse(resourceContents));
			case R5:
				return new org.hl7.fhir.r5.formats.JsonParser().parse(resourceContents);
			default:
				log.error("FHIR version not support for loading from matchbox case ");
				throw new RuntimeException(Msg.code(1305) + "Failed to load package resource " + describedBy);
			}
		} catch (Exception e) {
			throw new RuntimeException(Msg.code(1305) + "Failed to load package resource " + describedBy, e);
		}
	}

	/**
	 * The conformance resource types that are loaded from a package into the validation context. Shared by the eager
	 * and the lazy paths so that both register exactly the same set.
	 */
	private static final String[] CONFORMANCE_RESOURCE_TYPES = {
		"NamingSystem", "CapabilityStatement", "CodeSystem", "ValueSet", "StructureDefinition", "Measure", "Library",
		"ConceptMap", "SearchParameter", "StructureMap", "Questionnaire", "OperationDefinition", "ActorDefinition",
		"Requirements"
	};

	/**
	 * Registers a package's conformance resources without parsing them.
	 *
	 * The npm tables already index every resource in a package by canonical URL, version and type, which is all the
	 * context needs to resolve a canonical. A {@link CanonicalResourceProxy} is registered per row and the body is
	 * parsed only when something asks for the resource. A CH ELM engine loads around 10000 conformance resources
	 * across its dependency closure while a single validation reaches roughly a tenth of them, so most of that
	 * parsing is never needed.
	 *
	 * NpmPackage.canLazyLoad() is false for packages served from the JPA cache, since they are materialised in
	 * memory rather than streamed from disk, so the package index cannot be used for this and the database rows are
	 * used instead.
	 *
	 * Resolution behaviour is unchanged: every resource stays resolvable, it is just materialised later.
	 *
	 * @return the number of resources registered.
	 */
	/**
	 * Derives the resource id for a deferred load registration.
	 *
	 * The npm resource table does not store the FHIR resource id, and CanonicalResourceManager refuses to register a
	 * proxy without one. Package files are named "<Type>-<id>.json" by the IG publisher, so the filename gives it;
	 * where it does not, the last segment of the canonical URL is the conventional fallback.
	 */
	private static String deferredLoadId(final NpmPackageVersionResourceEntity row) {
		String filename = row.getFilename();
		if (filename != null) {
			final int slash = filename.lastIndexOf('/');
			if (slash >= 0) {
				filename = filename.substring(slash + 1);
			}
			if (filename.endsWith(".json")) {
				filename = filename.substring(0, filename.length() - ".json".length());
			}
			final String prefix = row.getResourceType() + "-";
			if (filename.startsWith(prefix)) {
				filename = filename.substring(prefix.length());
			}
			if (!filename.isEmpty()) {
				return filename;
			}
		}
		final String url = row.getCanonicalUrl();
		final int slash = url.lastIndexOf('/');
		return (slash >= 0 && slash < url.length() - 1) ? url.substring(slash + 1) : url;
	}

	/**
	 * Registers a package's conformance resources without parsing them.
	 *
	 * The package is already held in memory by the time it gets here, so the cost being deferred is the JSON parse
	 * and the version conversion to R5, not I/O. The package index carries what the context needs to resolve a
	 * canonical (type, id, url, version), so a {@link CanonicalResourceProxy} is registered per entry and the body is
	 * parsed only when something asks for the resource. A CH ELM engine loads around 10000 conformance resources
	 * across its dependency closure while a single validation reaches roughly a tenth of them.
	 *
	 * This deliberately does not go through the JPA entities: NpmPackageVersionEntity.getResources() would pull tens
	 * of thousands of rows into the persistence context, which stays open for the whole recursive load, and Hibernate
	 * then auto-flushes over all of them on every later query. That is quadratic and ends up far slower than the
	 * eager load it replaces.
	 *
	 * Resolution behaviour is unchanged: every resource stays resolvable, it is just materialised later.
	 *
	 * @return the number of resources registered.
	 */
	private int registerResourcesLazily(final NpmPackage pi,
													final String fhirVersion,
													final PackageInformation packageInfo) throws IOException {
		int count = 0;
		for (final NpmPackage.PackageResourceInformation pri : pi.listIndexedResources(CONFORMANCE_RESOURCE_TYPES)) {
			if (pri.getUrl() == null) {
				// Nothing to resolve it by; the context indexes canonicals.
				continue;
			}
			++count;
			this.getContext().registerResourceFromPackage(new CanonicalResourceProxy(pri.getResourceType(),
																												 pri.getId(),
																												 pri.getUrl(),
																												 pri.getVersion(),
																												 pri.getSupplements(),
																												 pri.getContent(),
																												 pri.getDerivation()) {
				@Override
				public CanonicalResource loadResource() throws FHIRException {
					final Resource r;
					try {
						r = loadResourceByVersion(fhirVersion,
														  FileUtilities.streamToBytes(pi.load(pri)),
														  pri.getFilename());
					} catch (final IOException e) {
						throw new FHIRException("Failed to lazily load " + pri.getFilename() + " from "
														  + packageInfo.getVID(), e);
					}
					// Same cleanups the eager path applies, see ahdis/matchbox#227.
					if (r instanceof org.hl7.fhir.r5.model.StructureMap sm) {
						cleanModifierExtensions(sm);
					}
					if (r instanceof org.hl7.fhir.r5.model.ConceptMap cm) {
						cleanModifierExtensions(cm);
					}
					if (!(r instanceof CanonicalResource)) {
						throw new FHIRException("Resource is not a CanonicalResource: " + r.getClass().getName()
														  + " from package " + packageInfo.getVID());
					}
					return (CanonicalResource) r;
				}
			}, packageInfo);
		}
		return count;
	}

	@Override
	public void loadIg(List<ImplementationGuide> igs, Map<String, ByteProvider> binaries, String src, boolean recursive)
			throws IOException, FHIRException {

		switch (FhirVersionEnum.forVersionString(this.getVersion())) {
			case R4, R4B -> {
				if (src.startsWith("hl7.terminology#7.3.0")) {
					log.info("Requesting to load '{}', loading '{}' instead'", src, PACKAGE_R4_TERMINOLOGY);
					loadIg(igs, binaries, PACKAGE_R4_TERMINOLOGY, recursive);
					return;
				}
				if (src.startsWith("hl7.fhir.uv.extensions#5.3.0")) {
					log.info("Requesting to load '{}', loading '{}' instead'", src, PACKAGE_R4_UV_EXTENSIONS);
					loadIg(igs, binaries, PACKAGE_R4_UV_EXTENSIONS, recursive);
					return;
				}
			}
			case R5 -> {
				if (src.startsWith("hl7.terminology#7.3.0")) {
					log.info("Requesting to load '{}', loading '{}' instead'", src, PACKAGE_R5_TERMINOLOGY);
					loadIg(igs, binaries, PACKAGE_R5_TERMINOLOGY, recursive);
					return;
				}
				if (src.startsWith("hl7.fhir.uv.extensions#5.3.0")) {
					log.info("Requesting to load '{}', loading from classpath '{}' instead'", src, PACKAGE_R5_UV_EXTENSIONS);
					loadIg(igs, binaries, PACKAGE_R5_UV_EXTENSIONS, recursive);
					return;
				}
			}
			default -> throw new MatchboxUnsupportedFhirVersionException("IgLoaderFromJpaPackageCache",
																							 this.myCtx.getVersion().getVersion());
		};
		if (src.equals("hl7.fhir.cda#dev")) {
			log.info("Replacing 'hl7.fhir.cda#dev' with '{}'", PACKAGE_CDA_UV_CORE);
			loadIg(igs, binaries, PACKAGE_CDA_UV_CORE, recursive);
			return;
		}
		if (getContext().getLoadedPackages().contains(src)) {
			log.info("Package '{}' already in context", src);
			return;
		}
		if (this.getVersion()!=null && getVersion().equals("5.0.0") && (src.startsWith("hl7.fhir.r4.core") || src.startsWith("hl7.fhir.uv.extensions.r4")) ) {
			log.info("do not load r4 in a r5 context: '{}'", src);
			return;
		}
		new TransactionTemplate(myTxManager).execute(tx -> {
			String version = null;
			String id = src;
			if (src.contains("#")) {
				version = src.substring(src.indexOf("#") + 1);
				id = src.substring(0, src.indexOf("#"));
			}
			NpmPackage npm = ((JpaPackageCache) myPackageCacheManager).loadPackageFromCacheOnly(id, version);
			if (npm == null) {
				log.error("Package not found: " + id +" "+version );
				return null;
			}
			for (final String dependency : npm.dependencies()) {
				if (VersionUtilities.isCorePackage(dependency)) {
					// The FHIR core package is loaded manually for the FHIR version of the engine, see
					// MatchboxEngineSupport.getMatchboxEngineNotSynchronized(). Loading the core package of another FHIR
					// version as a dependency would add a second set of type definitions to the context, which makes the
					// validation fail with 'Ambiguous type id'. The official validator skips core packages in the
					// dependencies too, see org.hl7.fhir.validation.IgLoader#loadIg(..).
					log.info("Ignoring core dependency '{}' for '{}'", dependency, src);
					continue;
				}
				log.debug("Loading depending package " + dependency + " for "+src);
				try {
					loadIg(igs, binaries, dependency, recursive);
				} catch (FHIRException | IOException e) {
					throw new RuntimeException(Msg.code(1305) + "Failed to load dependency " + dependency, e);
				}
				log.info("Finished loading depending package " + dependency + " for "+ src);
			}
			// Load internal dependencies declared in the ImplementationGuide resource (see #481)
			for (final String internalDep : getInternalDependencies(npm)) {
				if (VersionUtilities.isCorePackage(internalDep)) {
					log.info("Ignoring core internal dependency '{}' for '{}'", internalDep, src);
					continue;
				}
				log.debug("Loading internal dependency " + internalDep + " for " + src);
				try {
					loadIg(igs, binaries, internalDep, recursive);
				} catch (FHIRException | IOException e) {
					log.warn("Failed to load internal dependency " + internalDep + " for " + src, e);
				}
				log.info("Finished loading internal dependency " + internalDep + " for " + src);
			}
			// use above version because of potential .x version we resolve in the cache
			version = npm.version();
			Optional<NpmPackageVersionEntity> npmPackage = myNpmPackageVersionDao.findByPackageIdAndVersion(id, version);
			if (npmPackage.isPresent()) {
				int count = 0;
				log.info("Loading package " + src);

				// this way we have 0.5 seconds per 100 resources (eg hl7.fhir.r4.core has 15 seconds for 3128 resources)
				NpmPackage pi = this.loadPackage(npmPackage.get());
				PackageInformation packageInfo = new PackageInformation(pi);
				getContext().getLoadedPackages().add(pi.name() + "#" + pi.version());
				
				try {
					if (this.lazyLoadPackageResources) {
						count = registerResourcesLazily(pi, npm.fhirVersion(), packageInfo);
						log.info("Registered " + count + " conformance resources lazily for package " + pi.name() + "#" + pi.version());
						return null;
					}
					for (String s : pi.listResources(CONFORMANCE_RESOURCE_TYPES)) {
						++count;
						Resource r = null;
						try {
							r = loadResourceByVersion(npm.fhirVersion(), FileUtilities.streamToBytes(pi.load("package", s)), s);
							// https://github.com/ahdis/matchbox/issues/227
							if (r instanceof org.hl7.fhir.r5.model.StructureMap ) {
								cleanModifierExtensions((org.hl7.fhir.r5.model.StructureMap) r);
							}			
							if (r instanceof org.hl7.fhir.r5.model.ConceptMap ) {
								cleanModifierExtensions((org.hl7.fhir.r5.model.ConceptMap) r);
							}			
							if (r instanceof CanonicalResource) {
								// go through context to replace to newer version if needed (see ahdis/matchbox#447)
								this.getContext().cacheResourceFromPackage(r, packageInfo);
							} else {
								log.error("Resource is not a CanonicalResource: " + r.getClass().getName() + " from package " +pi.name() + "#" + pi.version());
							}
						} catch (FHIRException e) {
							log.error(s, e);
						} catch (IOException e) {
							log.error(s, e);
						}
					}
				} catch (IOException e) {
					log.error("Error reading package", e);
					return null;
				}

				log.info("Finished loading " + count + " conformance resources for package " + pi.name() + "#" + pi.version());

				// with hsql or psql this slow around 7 seconds per 100 resources (oe dev)
				// machine)
				// lets load the package directly
//				List<NpmPackageVersionResourceEntity> resources = npmPackage.get().getResources();
//				for (NpmPackageVersionResourceEntity resource: resources) {
//					++count;
//					if (count % 100 == 0) {
//						log.info(" ... loading "+count);
//					}
//					this.getContext().cacheResource(loadPackageEntity(resource));
//				}
//s				this.getContext().getLoadedPackages().add(id + "#" + version);


			} else {
				throw new RuntimeException(Msg.code(1305) + "Failed to load package resource " + src);
			}
			return null;
		});
	}

	/**
	 * Extracts internal dependencies from the ImplementationGuide resource in the package.
	 * These are declared via the ig-internal-dependency extension in the IG definition,
	 * and are not listed in package.json dependencies.
	 * See https://github.com/ahdis/matchbox/issues/481
	 */
	private List<String> getInternalDependencies(NpmPackage npm) {
		List<String> result = new ArrayList<>();
		try {
			for (String s : npm.listResources("ImplementationGuide")) {
				byte[] content = FileUtilities.streamToBytes(npm.load("package", s));
				org.hl7.fhir.utilities.json.model.JsonObject igJson =
					org.hl7.fhir.utilities.json.parser.JsonParser.parseObject(content);
				org.hl7.fhir.utilities.json.model.JsonObject definition = igJson.getJsonObject("definition");
				if (definition != null && definition.has("extension")) {
					for (org.hl7.fhir.utilities.json.model.JsonObject ext : definition.getJsonObjects("extension")) {
						String url = ext.asString("url");
						if ("http://hl7.org/fhir/tools/StructureDefinition/ig-internal-dependency".equals(url)) {
							String value = ext.asString("valueCode");
							if (value != null && value.contains("#") && !value.startsWith("hl7.fhir.uv.tools")) {
								result.add(value);
							}
						}
					}
				}
			}
		} catch (IOException e) {
			log.warn("Failed to read ImplementationGuide resources from package {}: {}", npm.name(), e.getMessage());
		}
		return result;
	}

	private NpmPackage loadPackage(NpmPackageVersionEntity thePackageVersion) {
		PackageContents content = loadPackageContents(thePackageVersion);
		ByteArrayInputStream inputStream = new ByteArrayInputStream(content.getBytes());
		try {
			return NpmPackage.fromPackage(inputStream);
		} catch (IOException e) {
			throw new InternalErrorException(Msg.code(1294) + e);
		}
	}

	private IHapiPackageCacheManager.PackageContents loadPackageContents(NpmPackageVersionEntity thePackageVersion) {
		final var binary = MatchboxServerUtils.getBinaryFromId(thePackageVersion.getPackageBinary().getId(), myDaoRegistry);
		try {
			final byte[] content = MatchboxServerUtils.fetchBlobFromBinary(binary, myBinaryStorageSvc, myCtx);
			PackageContents retVal = new PackageContents().setBytes(content).setPackageId(thePackageVersion.getPackageId())
					.setVersion(thePackageVersion.getVersionId()).setLastModified(thePackageVersion.getUpdatedTime());
			return retVal;
		} catch (IOException e) {
			throw new InternalErrorException(Msg.code(1295) + "Failed to load package. There was a problem reading binaries",
					e);
		}
	}

	/**
	 * we want to load directly from the jpa package manager internet package cache
	 * manager
	 */
	@Override
	public Map<String, ByteProvider> loadIgSource(String src, boolean recursive, boolean explore)
			throws FHIRException, IOException {
		throw new RuntimeException(Msg.code(1305) + "Failed to load package, should not be here (loadIgSource) " + src);
	}

	/**
	 * we overwrite this method to not provoke depend packages to be loaded,
	 * otherwise we get cda-core-2.0.tgz .. load IG from hl7.terminology.r4#5.4.0
	 */
	public Map<String, ByteProvider> loadPackage(NpmPackage pi, boolean loadInContext) throws FHIRException, IOException {
		throw new RuntimeException(Msg.code(1305) + "Failed to load package, should not be her (loadpackage) " + pi);
	}

}
