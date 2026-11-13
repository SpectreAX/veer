# gomobile's generated Java surface is reached both directly and through
# reflection (for compatibility across AAR revisions). Renaming or removing a
# native method breaks JNI symbol lookup even when Kotlin compilation succeeds.
-keep class veercore.** { *; }
-keep interface veercore.** { *; }

# Keep useful line numbers for locally exported crash diagnostics while hiding
# host source paths and original source file names.
-keepattributes SourceFile,LineNumberTable,Signature,InnerClasses,EnclosingMethod
-renamesourcefileattribute SourceFile

# SnakeYAML contains optional JavaBeans introspection support for desktop JVMs.
# Veer only uses SafeConstructor into maps/lists and never enters that branch;
# Android intentionally does not ship java.beans.
-dontwarn java.beans.BeanInfo
-dontwarn java.beans.FeatureDescriptor
-dontwarn java.beans.IntrospectionException
-dontwarn java.beans.Introspector
-dontwarn java.beans.PropertyDescriptor

# SafeConstructor still performs reflective class/resource discovery internally.
# Keeping SnakeYAML avoids release-only parser failures after R8 optimization.
-keep class org.yaml.snakeyaml.** { *; }
