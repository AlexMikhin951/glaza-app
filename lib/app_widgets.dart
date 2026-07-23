import 'package:flutter/material.dart';
import 'app_theme.dart';

class GradientBackground extends StatelessWidget {
  final Widget child;
  const GradientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppColors.gradientBackground),
      child: child,
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: glassCardDecoration(borderColor: borderColor),
      child: child,
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: AppColors.gradientPrimary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;

  const GradientButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || isLoading;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: disabled ? null : AppColors.gradientPrimary,
        color: disabled ? AppColors.surfaceLight : null,
        borderRadius: BorderRadius.circular(16),
        boxShadow: disabled
            ? null
            : [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.4),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled ? null : onPressed,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: double.infinity,
            height: 54,
            child: Center(
              child: isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: Colors.white, size: 20),
                          const SizedBox(width: 10),
                        ],
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: disabled
                                ? AppColors.textMuted
                                : Colors.white,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class PlaceChip extends StatelessWidget {
  final String name;
  final String address;
  final VoidCallback onDelete;

  const PlaceChip({
    super.key,
    required this.name,
    required this.address,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.glassBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.place_rounded, color: AppColors.accent, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '"$name"',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  address,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            color: AppColors.error.withValues(alpha: 0.8),
            onPressed: onDelete,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

class StatusBanner extends StatelessWidget {
  final String text;
  final bool isError;

  const StatusBanner({super.key, required this.text, this.isError = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: (isError ? AppColors.error : AppColors.warning)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (isError ? AppColors.error : AppColors.warning)
              .withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            color: isError ? AppColors.error : AppColors.warning,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: isError ? AppColors.error : AppColors.warning,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HeroIcon extends StatelessWidget {
  const HeroIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppColors.gradientHero,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.35),
                blurRadius: 40,
                spreadRadius: 4,
              ),
            ],
          ),
        ),
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.background.withValues(alpha: 0.85),
          ),
          child: ShaderMask(
            shaderCallback: (bounds) =>
                AppColors.gradientHero.createShader(bounds),
            child: const Icon(
              Icons.wifi_tethering_rounded,
              size: 44,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}
