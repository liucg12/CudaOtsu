#include <stdio.h>
#include <stdlib.h>

#include "PngImage.h"

// CUDA Runtime
#include <cuda_runtime.h>

__global__ void calculateHistogram(unsigned int* histogram, unsigned char* rawPixels, long chunkSize, long totalPixels)
{
	int id = blockDim.x * blockIdx.x + threadIdx.x;

	int startPosition = id * chunkSize;
	for (int i = startPosition; i < (startPosition + chunkSize); i++) {
		if (i < totalPixels) {
			int pixelValue = (int)rawPixels[i];
			atomicAdd(&histogram[pixelValue], 1);
		}
	}
}

__global__ void computeClassVariances(double* histogram, double allProbabilitySum, long int totalPixels, double* betweenClassVariance)
{
	int id = blockDim.x * blockIdx.x + threadIdx.x;

	double firstClassProbability = 0, secondClassProbability = 0;
	double firstClassMean = 0, secondClassMean = 0;
	double firstProbabilitySum = 0;

	for (int t = 0; t <= id; t++) {
		firstClassProbability += histogram[t];
		firstProbabilitySum += t * firstClassProbability;
	}

	secondClassProbability = 1 - firstClassProbability;

	firstClassMean = (double)firstProbabilitySum / (double)firstClassProbability;
	secondClassMean = (double)(allProbabilitySum - firstProbabilitySum) / (double)secondClassProbability;

	betweenClassVariance[id] = firstClassProbability * secondClassProbability * pow((firstClassMean - secondClassMean), 2);
}

__global__ void binarize(unsigned char* rawPixels, long totalPixels, long chunkSize, unsigned char threshold)
{
	int id = blockDim.x * blockIdx.x + threadIdx.x;

	int startPosition = id * chunkSize;
	for (int i = startPosition; i < (startPosition + chunkSize); i++) {
		if (i < totalPixels) {
			if ((int)rawPixels[i] > (int)threshold) {
				rawPixels[i] = PngImage::COLOR_WHITE;
			}
			else {
				rawPixels[i] = PngImage::COLOR_BLACK;
			}
		}
	}
}

extern "C" double* cudaCalculateHistogram(unsigned char* rawPixels, long totalPixels) {
	int threadsPerBlock = 256;
	int numBlocks = 256;

	//TODO: check cudaGetDeviceProperties function!
	 
	unsigned int* hostHistogram = new unsigned int[PngImage::MAX_PIXEL_VALUE];
	for (int i = 0; i < PngImage::MAX_PIXEL_VALUE; i++) {
		hostHistogram[i] = 0;
	}

	unsigned int* deviceHistogram;
	cudaMalloc((void **)&deviceHistogram, sizeof(unsigned int) * PngImage::MAX_PIXEL_VALUE);
	cudaMemcpy(deviceHistogram, hostHistogram, sizeof(unsigned int) * PngImage::MAX_PIXEL_VALUE, cudaMemcpyHostToDevice);

	unsigned char* deviceRawPixels;
	cudaMalloc((void **)&deviceRawPixels, sizeof(unsigned char) * totalPixels);
	cudaMemcpy(deviceRawPixels, rawPixels, sizeof(unsigned char) * totalPixels, cudaMemcpyHostToDevice);

	long chunkSize = ceil(totalPixels / (threadsPerBlock * numBlocks)) + 1;

	calculateHistogram<<<numBlocks, threadsPerBlock>>>(deviceHistogram, deviceRawPixels, chunkSize, totalPixels);

	cudaMemcpy(hostHistogram, deviceHistogram, sizeof(unsigned int) * PngImage::MAX_PIXEL_VALUE, cudaMemcpyDeviceToHost);

	cudaFree(deviceHistogram);
	cudaFree(deviceRawPixels);

	double* normalizedHistogram = new double[PngImage::MAX_PIXEL_VALUE];
	for (int v = 0; v < PngImage::MAX_PIXEL_VALUE; v++) {
		normalizedHistogram[v] = (double)hostHistogram[v] / (double)totalPixels;
	}

	free(hostHistogram);

	return normalizedHistogram;
}

extern "C" unsigned char cudaFindThreshold(double* histogram, long int totalPixels) {
	int threadsPerBlock = 256;
	int numBlocks = 256;

	double allProbabilitySum = 0;
	for (int i = 0; i < PngImage::MAX_PIXEL_VALUE; i++) {
		allProbabilitySum += i * histogram[i];
	}

	double* hostBetweenClassVariances = new double[PngImage::MAX_PIXEL_VALUE];
	for (int i = 0; i < PngImage::MAX_PIXEL_VALUE; i++) {
		hostBetweenClassVariances[i] = 0;
	}

	double* deviceHistogram;
	cudaMalloc((void **)&deviceHistogram, sizeof(double) * PngImage::MAX_PIXEL_VALUE);
	cudaMemcpy(deviceHistogram, histogram, sizeof(double) * PngImage::MAX_PIXEL_VALUE, cudaMemcpyHostToDevice);

	double* deviceBetweenClassVariances;
	cudaMalloc((void **)&deviceBetweenClassVariances, sizeof(double) * PngImage::MAX_PIXEL_VALUE);
	cudaMemcpy(deviceBetweenClassVariances, hostBetweenClassVariances, sizeof(double) * PngImage::MAX_PIXEL_VALUE, cudaMemcpyHostToDevice);

	computeClassVariances<<<numBlocks, threadsPerBlock>>>(deviceHistogram, allProbabilitySum, totalPixels, deviceBetweenClassVariances);

	cudaMemcpy(hostBetweenClassVariances, deviceBetweenClassVariances, sizeof(unsigned int) * PngImage::MAX_PIXEL_VALUE, cudaMemcpyDeviceToHost);

	cudaFree(deviceHistogram);
	cudaFree(deviceBetweenClassVariances);

	double maxVariance = 0;
	unsigned char currentBestThreshold = 0;
	for (int t = 0; t < PngImage::MAX_PIXEL_VALUE; t++) {
		if (hostBetweenClassVariances[t] > maxVariance) {
			currentBestThreshold = (unsigned char)t;
			maxVariance = hostBetweenClassVariances[t];
		}
	}

	return currentBestThreshold;
}

extern "C" unsigned char* cudaBinarize(unsigned char* rawPixels, long totalPixels, unsigned char threshold) {
	int threadsPerBlock = 256;
	int numBlocks = 256;

	unsigned char* hostRawPixels = new unsigned char[totalPixels];

	unsigned char* deviceRawPixels;
	cudaMalloc((void **)&deviceRawPixels, sizeof(unsigned char) * totalPixels);
	cudaMemcpy(deviceRawPixels, rawPixels, totalPixels * sizeof(unsigned char), cudaMemcpyHostToDevice);

	long chunkSize = ceil(totalPixels / (threadsPerBlock * numBlocks)) + 1;

	binarize<<<numBlocks, threadsPerBlock>>>(deviceRawPixels, totalPixels, chunkSize, threshold);

	cudaMemcpy(hostRawPixels, deviceRawPixels, sizeof(unsigned char) * totalPixels, cudaMemcpyDeviceToHost);

	cudaFree(deviceRawPixels);

	return hostRawPixels;
}