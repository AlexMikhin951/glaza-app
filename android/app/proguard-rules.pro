# Подавляем R8-ошибки на отсутствующие java.beans.* классы (десктопный JDK API,
# на Android никогда не существовал). Их транзитивно тянет org.yaml.snakeyaml,
# но этот код-путь не используется в рантайме приложения.
-dontwarn java.beans.BeanInfo
-dontwarn java.beans.FeatureDescriptor
-dontwarn java.beans.IntrospectionException
-dontwarn java.beans.Introspector
-dontwarn java.beans.PropertyDescriptor

# На случай, если R8 найдёт ещё что-то похожее в snakeyaml — общее правило:
-dontwarn org.yaml.snakeyaml.**