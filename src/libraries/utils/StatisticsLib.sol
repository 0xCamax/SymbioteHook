// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "./Math.sol";

library StatisticsLib {
    /**
     * @dev Calculate the arithmetic mean of an array of integers
     * @param data Array of integers
     * @return The mean value
     */
    function mean(int256[] memory data) internal pure returns (int256) {
        require(data.length > 0, "Empty data array");

        int256 s = 0;
        uint256 len = data.length;

        assembly {
            let dataPtr := add(data, 0x20)

            for { let i := 0 } lt(i, len) { i := add(i, 1) } { s := add(s, mload(add(dataPtr, mul(i, 0x20)))) }
        }

        return s / int256(len);
    }

    /**
     * @dev Calculate the sum of an array of integers
     * @param data Array of integers
     * @return The sum value
     */
    function sum(int256[] memory data) internal pure returns (int256) {
        require(data.length > 0, "Empty data array");

        int256 total = 0;
        uint256 len = data.length;

        assembly {
            let dataPtr := add(data, 0x20)

            for { let i := 0 } lt(i, len) { i := add(i, 1) } { total := add(total, mload(add(dataPtr, mul(i, 0x20)))) }
        }

        return total;
    }

    /**
     * @dev Calculate the variance of an array of integers
     * @param data Array of integers
     * @param usePopulation If true, uses population variance (N), if false uses sample variance (N-1)
     * @return The variance value
     */
    function variance(int256[] memory data, bool usePopulation) internal pure returns (uint256) {
        uint256 n = data.length;
        require(n > 0, "Empty data array");
        require(!(!usePopulation && n == 1), "Sample variance requires at least 2 data points");

        int256 meanValue = mean(data);
        uint256 varianceSum = 0;

        assembly {
            let dataPtr := add(data, 0x20)

            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let value := mload(add(dataPtr, mul(i, 0x20)))
                let diff := sub(value, meanValue)
                varianceSum := add(varianceSum, mul(diff, diff))
            }
        }

        uint256 divisor = usePopulation ? n : n - 1;
        return varianceSum / divisor;
    }

    /**
     * @dev Calculate the population variance of an array of integers
     * @param data Array of integers
     * @return The population variance value
     */
    function populationVariance(int256[] memory data) internal pure returns (uint256) {
        return variance(data, true);
    }

    /**
     * @dev Calculate the sample variance of an array of integers
     * @param data Array of integers
     * @return The sample variance value
     */
    function sampleVariance(int256[] memory data) internal pure returns (uint256) {
        return variance(data, false);
    }

    /**
     * @dev Calculate the standard deviation of an array of integers
     * @param data Array of integers
     * @param usePopulation If true, uses population std dev, if false uses sample std dev
     * @return The standard deviation value
     */
    function standardDeviation(int256[] memory data, bool usePopulation) internal pure returns (uint256) {
        uint256 varianceValue = variance(data, usePopulation);
        return Math.sqrt(varianceValue);
    }

    /**
     * @dev Calculate the population standard deviation of an array of integers
     * @param data Array of integers
     * @return The population standard deviation value
     */
    function populationStandardDeviation(int256[] memory data) internal pure returns (uint256) {
        return standardDeviation(data, true);
    }

    /**
     * @dev Calculate the sample standard deviation of an array of integers
     * @param data Array of integers
     * @return The sample standard deviation value
     */
    function sampleStandardDeviation(int256[] memory data) internal pure returns (uint256) {
        return standardDeviation(data, false);
    }

    /**
     * @dev Find the minimum value in an array of integers
     * @param data Array of integers
     * @return The minimum value
     */
    function min(int256[] memory data) internal pure returns (int256) {
        require(data.length > 0, "Empty data array");

        int256 minValue = data[0];
        uint256 len = data.length;

        assembly {
            let dataPtr := add(data, 0x20)
            minValue := mload(dataPtr)

            for { let i := 1 } lt(i, len) { i := add(i, 1) } {
                let value := mload(add(dataPtr, mul(i, 0x20)))
                if lt(value, minValue) { minValue := value }
            }
        }

        return minValue;
    }

    /**
     * @dev Find the maximum value in an array of integers
     * @param data Array of integers
     * @return The maximum value
     */
    function max(int256[] memory data) internal pure returns (int256) {
        require(data.length > 0, "Empty data array");

        int256 maxValue = data[0];
        uint256 len = data.length;

        assembly {
            let dataPtr := add(data, 0x20)
            maxValue := mload(dataPtr)

            for { let i := 1 } lt(i, len) { i := add(i, 1) } {
                let value := mload(add(dataPtr, mul(i, 0x20)))
                if gt(value, maxValue) { maxValue := value }
            }
        }

        return maxValue;
    }

    /**
     * @dev Calculate the range (max - min) of an array of integers
     * @param data Array of integers
     * @return The range value
     */
    function range(int256[] memory data) internal pure returns (int256) {
        return max(data) - min(data);
    }

    /**
     * @dev Calculate the median of an array of integers
     * @param data Array of integers (will be modified/sorted)
     * @return The median value
     */
    function median(int256[] memory data) internal pure returns (int256) {
        require(data.length > 0, "Empty data array");

        // Simple bubble sort (not gas efficient for large arrays)
        uint256 n = data.length;
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (data[j] > data[j + 1]) {
                    int256 temp = data[j];
                    data[j] = data[j + 1];
                    data[j + 1] = temp;
                }
            }
        }

        if (n % 2 == 0) {
            // Even number of elements - return average of middle two
            return (data[n / 2 - 1] + data[n / 2]) / 2;
        } else {
            // Odd number of elements - return middle element
            return data[n / 2];
        }
    }
}
