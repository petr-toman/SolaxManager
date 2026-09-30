import unittest

from reporter import split_signed_kwh, trapezoid_kwh


class IntegrationMathTests(unittest.TestCase):
    def test_constant_trapezoid(self):
        self.assertAlmostEqual(trapezoid_kwh(1000, 1000, 3600), 1.0)

    def test_zero_crossing_is_split(self):
        positive, negative = split_signed_kwh(-1000, 1000, 3600)
        self.assertAlmostEqual(positive, 0.25)
        self.assertAlmostEqual(negative, 0.25)

    def test_negative_segment_is_absolute_in_negative_bucket(self):
        positive, negative = split_signed_kwh(-1000, -1000, 1800)
        self.assertAlmostEqual(positive, 0.0)
        self.assertAlmostEqual(negative, 0.5)


if __name__ == "__main__":
    unittest.main()
